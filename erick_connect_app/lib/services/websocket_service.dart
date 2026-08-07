import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_constants.dart';
import '../utils/socket_channel_factory.dart';
import '../utils/ws_utils.dart';
import 'auth_service.dart';
import 'logger_service.dart';

enum WebSocketConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// Centralized WebSocket service for passenger and driver connections.
class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _passengerSocket;
  WebSocketChannel? _driverSocket;
  StreamSubscription<dynamic>? _passengerSubscription;
  StreamSubscription<dynamic>? _driverSubscription;
  Future<void>? _passengerConnectFuture;
  Future<void>? _driverConnectFuture;

  final _passengerMessageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _driverMessageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _passengerReconnectController = StreamController<void>.broadcast();
  final _driverReconnectController = StreamController<void>.broadcast();
  final _passengerStatusController =
      StreamController<WebSocketConnectionStatus>.broadcast();
  final _driverStatusController =
      StreamController<WebSocketConnectionStatus>.broadcast();

  bool _passengerConnected = false;
  bool _driverConnected = false;
  WebSocketConnectionStatus _passengerStatus =
      WebSocketConnectionStatus.disconnected;
  WebSocketConnectionStatus _driverStatus =
      WebSocketConnectionStatus.disconnected;
  Timer? _passengerReconnectTimer;
  Timer? _driverReconnectTimer;
  Timer? _passengerRecoveryProbeTimer;
  Timer? _driverRecoveryProbeTimer;
  Timer? _passengerTokenRefreshTimer;
  Timer? _driverTokenRefreshTimer;
  int _passengerReconnectAttempts = 0;
  int _driverReconnectAttempts = 0;
  Future<void>? _resumeRecoveryFuture;

  String? _passengerJwtToken;
  String? _driverJwtToken;

  static const int _maxReconnectAttempts =
      WebSocketConstants.maxReconnectAttempts;
  static const Duration _baseReconnectDelay =
      WebSocketConstants.baseReconnectDelay;
  static const Duration _maxReconnectDelay =
      WebSocketConstants.maxReconnectDelay;
  static const Duration _connectionTimeout =
      WebSocketConstants.connectionTimeout;
  static const Duration _tokenRefreshWindow = Duration(seconds: 30);
  static const Duration _tokenRefreshRetryDelay = Duration(seconds: 5);

  final Random _random = Random();

  Stream<Map<String, dynamic>> get passengerMessages =>
      _passengerMessageController.stream;

  Stream<Map<String, dynamic>> get driverMessages =>
      _driverMessageController.stream;

  /// Emits after a passenger socket recovers from an outage or token rotation.
  Stream<void> get passengerReconnected => _passengerReconnectController.stream;

  /// Emits after a driver socket recovers from an outage or token rotation.
  Stream<void> get driverReconnected => _driverReconnectController.stream;

  Stream<WebSocketConnectionStatus> get passengerConnectionStates =>
      _passengerStatusController.stream;

  Stream<WebSocketConnectionStatus> get driverConnectionStates =>
      _driverStatusController.stream;

  WebSocketConnectionStatus get passengerConnectionStatus => _passengerStatus;

  WebSocketConnectionStatus get driverConnectionStatus => _driverStatus;

  bool get isPassengerConnected =>
      _passengerConnected && _passengerSocket != null;

  bool get isDriverConnected => _driverConnected && _driverSocket != null;

  /// Revalidates active sockets after the app returns to the foreground.
  ///
  /// Mobile operating systems may silently suspend or discard TCP connections
  /// while the app is backgrounded, so a fresh handshake is safer than trusting
  /// the old channel's in-memory state.
  Future<void> recoverConnectionsAfterResume() async {
    final existing = _resumeRecoveryFuture;
    if (existing != null) return existing;

    late final Future<void> recovery;
    recovery = _recoverConnectionsAfterResume();
    _resumeRecoveryFuture = recovery;
    try {
      await recovery;
    } finally {
      if (identical(_resumeRecoveryFuture, recovery)) {
        _resumeRecoveryFuture = null;
      }
    }
  }

  Future<void> _recoverConnectionsAfterResume() async {
    final recoveries = <Future<void>>[];
    if (_passengerJwtToken != null) {
      recoveries.add(_recoverPassengerAfterResume());
    }
    if (_driverJwtToken != null) {
      recoveries.add(_recoverDriverAfterResume());
    }
    await Future.wait(recoveries);
  }

  Future<void> _recoverPassengerAfterResume() async {
    _passengerReconnectAttempts = 0;
    await _replacePassengerSocket();
    try {
      await _connectPassenger(isRecovery: true);
    } catch (error) {
      Logger.warning(
        'Passenger WebSocket resume recovery failed: '
        '${_redactError(error, _passengerJwtToken)}',
        tag: 'WebSocket',
      );
    }
  }

  Future<void> _recoverDriverAfterResume() async {
    _driverReconnectAttempts = 0;
    await _replaceDriverSocket();
    try {
      await _connectDriver(isRecovery: true);
    } catch (error) {
      Logger.warning(
        'Driver WebSocket resume recovery failed: '
        '${_redactError(error, _driverJwtToken)}',
        tag: 'WebSocket',
      );
    }
  }

  /// Reconnect active sockets with a rotated access token.
  Future<void> reconnectWithAccessToken(String accessToken) async {
    if (accessToken.isEmpty) return;

    final reconnectPassenger = _passengerSocket != null || _passengerConnected;
    final reconnectDriver = _driverSocket != null || _driverConnected;

    if (reconnectPassenger) {
      _passengerJwtToken = accessToken;
      await _replacePassengerSocket();
      try {
        await _connectPassenger(isRecovery: true);
      } catch (error) {
        Logger.warning(
          'Passenger WebSocket token-rotation reconnect failed: '
          '${_redactError(error, accessToken)}',
          tag: 'WebSocket',
        );
      }
    }

    if (reconnectDriver) {
      _driverJwtToken = accessToken;
      await _replaceDriverSocket();
      try {
        await _connectDriver(isRecovery: true);
      } catch (error) {
        Logger.warning(
          'Driver WebSocket token-rotation reconnect failed: '
          '${_redactError(error, accessToken)}',
          tag: 'WebSocket',
        );
      }
    }
  }

  Future<void> _replacePassengerSocket() async {
    _passengerReconnectTimer?.cancel();
    _passengerReconnectTimer = null;
    _passengerTokenRefreshTimer?.cancel();
    _passengerTokenRefreshTimer = null;
    _passengerRecoveryProbeTimer?.cancel();
    _passengerRecoveryProbeTimer = null;
    _setPassengerStatus(WebSocketConnectionStatus.reconnecting);
    final subscription = _passengerSubscription;
    final socket = _passengerSocket;
    _passengerConnectFuture = null;
    _passengerSubscription = null;
    _passengerSocket = null;
    _passengerConnected = false;
    await subscription?.cancel();
    await _closeQuietly(socket);
  }

  Future<void> _replaceDriverSocket() async {
    _driverReconnectTimer?.cancel();
    _driverReconnectTimer = null;
    _driverTokenRefreshTimer?.cancel();
    _driverTokenRefreshTimer = null;
    _driverRecoveryProbeTimer?.cancel();
    _driverRecoveryProbeTimer = null;
    _setDriverStatus(WebSocketConnectionStatus.reconnecting);
    final subscription = _driverSubscription;
    final socket = _driverSocket;
    _driverConnectFuture = null;
    _driverSubscription = null;
    _driverSocket = null;
    _driverConnected = false;
    await subscription?.cancel();
    await _closeQuietly(socket);
  }

  /// Completes only after the passenger WebSocket handshake succeeds.
  Future<void> connectPassenger({required String? jwtToken}) async {
    if (jwtToken == null || jwtToken.isEmpty) {
      throw ArgumentError.value(
        jwtToken,
        'jwtToken',
        'An access token is required',
      );
    }
    _passengerJwtToken = jwtToken;

    if (isPassengerConnected) {
      Logger.websocket('Passenger WebSocket already connected');
      return;
    }

    _passengerReconnectTimer?.cancel();
    _passengerReconnectTimer = null;
    await _connectPassenger(isRecovery: _passengerReconnectAttempts > 0);
  }

  Future<void> _connectPassenger({required bool isRecovery}) async {
    final existing = _passengerConnectFuture;
    if (existing != null) return existing;

    _setPassengerStatus(
      isRecovery
          ? WebSocketConnectionStatus.reconnecting
          : WebSocketConnectionStatus.connecting,
    );
    late final Future<void> connection;
    connection = _openPassengerSocket(isRecovery: isRecovery);
    _passengerConnectFuture = connection;
    try {
      await connection;
    } finally {
      if (identical(_passengerConnectFuture, connection)) {
        _passengerConnectFuture = null;
      }
    }
  }

  Future<void> _openPassengerSocket({required bool isRecovery}) async {
    final storedToken = _passengerJwtToken;
    if (storedToken == null || storedToken.isEmpty) {
      throw StateError('No passenger access token is available');
    }

    String token;
    try {
      token = await _freshTokenIfNeeded(storedToken);
      _passengerJwtToken = token;
    } catch (error, stackTrace) {
      _schedulePassengerReconnect();
      Error.throwWithStackTrace(error, stackTrace);
    }

    final uri = buildWsUri('/ws/app/', queryParams: {'token': token});
    late final WebSocketChannel channel;
    try {
      channel = createPlatformWebSocket(
        uri,
        pingInterval: WebSocketConstants.pingInterval,
      );
    } catch (error, stackTrace) {
      Logger.warning(
        'Unable to create passenger WebSocket channel: '
        '${_redactError(error, token)}',
        tag: 'WebSocket',
      );
      _schedulePassengerReconnect();
      Error.throwWithStackTrace(
        const _WebSocketConnectionException(
          'Unable to establish passenger WebSocket connection',
        ),
        stackTrace,
      );
    }
    _passengerSocket = channel;
    _passengerConnected = false;

    var ready = false;
    var streamTerminated = false;
    var recoveryStarted = false;
    Object? streamError;

    _passengerSubscription = channel.stream.listen(
      (message) => _forwardMessage(
        message,
        _passengerMessageController,
        role: 'passenger',
      ),
      onError: (Object error) {
        if (!identical(_passengerSocket, channel)) return;
        streamTerminated = true;
        streamError = error;
        _passengerConnected = false;
        if (ready && !recoveryStarted) {
          recoveryStarted = true;
          unawaited(_recoverPassengerSocket(channel, error, token: token));
        }
      },
      onDone: () {
        if (!identical(_passengerSocket, channel)) return;
        streamTerminated = true;
        final closed = _SocketClosed(channel.closeCode, channel.closeReason);
        streamError ??= closed;
        _passengerConnected = false;
        if (ready && !recoveryStarted) {
          recoveryStarted = true;
          unawaited(
            _recoverPassengerSocket(
              channel,
              closed,
              token: token,
              closeCode: channel.closeCode,
              closeReason: channel.closeReason,
            ),
          );
        }
      },
      cancelOnError: false,
    );

    try {
      await channel.ready.timeout(_connectionTimeout);
      if (!identical(_passengerSocket, channel) || streamTerminated) {
        throw streamError ??
            StateError('Passenger WebSocket closed during connection');
      }

      ready = true;
      final recovered = isRecovery || _passengerReconnectAttempts > 0;
      _passengerConnected = true;
      _passengerReconnectAttempts = 0;
      _passengerRecoveryProbeTimer?.cancel();
      _passengerRecoveryProbeTimer = null;
      _schedulePassengerTokenRefresh(token);
      _setPassengerStatus(WebSocketConnectionStatus.connected);
      Logger.websocket('Passenger WebSocket connected');
      if (recovered && !_passengerReconnectController.isClosed) {
        _passengerReconnectController.add(null);
      }
    } catch (error, stackTrace) {
      _passengerConnected = false;
      if (identical(_passengerSocket, channel) && !recoveryStarted) {
        recoveryStarted = true;
        await _recoverPassengerSocket(
          channel,
          streamError ?? error,
          token: token,
          closeCode: channel.closeCode,
          closeReason: channel.closeReason,
        );
      }
      Error.throwWithStackTrace(
        const _WebSocketConnectionException(
          'Unable to establish passenger WebSocket connection',
        ),
        stackTrace,
      );
    }
  }

  /// Completes only after the driver WebSocket handshake succeeds.
  Future<void> connectDriver({required String? jwtToken}) async {
    if (jwtToken == null || jwtToken.isEmpty) {
      throw ArgumentError.value(
        jwtToken,
        'jwtToken',
        'An access token is required',
      );
    }
    _driverJwtToken = jwtToken;

    if (isDriverConnected) {
      Logger.websocket('Driver WebSocket already connected');
      return;
    }

    _driverReconnectTimer?.cancel();
    _driverReconnectTimer = null;
    await _connectDriver(isRecovery: _driverReconnectAttempts > 0);
  }

  Future<void> _connectDriver({required bool isRecovery}) async {
    final existing = _driverConnectFuture;
    if (existing != null) return existing;

    _setDriverStatus(
      isRecovery
          ? WebSocketConnectionStatus.reconnecting
          : WebSocketConnectionStatus.connecting,
    );
    late final Future<void> connection;
    connection = _openDriverSocket(isRecovery: isRecovery);
    _driverConnectFuture = connection;
    try {
      await connection;
    } finally {
      if (identical(_driverConnectFuture, connection)) {
        _driverConnectFuture = null;
      }
    }
  }

  Future<void> _openDriverSocket({required bool isRecovery}) async {
    final storedToken = _driverJwtToken;
    if (storedToken == null || storedToken.isEmpty) {
      throw StateError('No driver access token is available');
    }

    String token;
    try {
      token = await _freshTokenIfNeeded(storedToken);
      _driverJwtToken = token;
    } catch (error, stackTrace) {
      _scheduleDriverReconnect();
      Error.throwWithStackTrace(error, stackTrace);
    }

    final uri = buildWsUri('/ws/app/', queryParams: {'token': token});
    late final WebSocketChannel channel;
    try {
      channel = createPlatformWebSocket(
        uri,
        pingInterval: WebSocketConstants.pingInterval,
      );
    } catch (error, stackTrace) {
      Logger.warning(
        'Unable to create driver WebSocket channel: '
        '${_redactError(error, token)}',
        tag: 'WebSocket',
      );
      _scheduleDriverReconnect();
      Error.throwWithStackTrace(
        const _WebSocketConnectionException(
          'Unable to establish driver WebSocket connection',
        ),
        stackTrace,
      );
    }
    _driverSocket = channel;
    _driverConnected = false;

    var ready = false;
    var streamTerminated = false;
    var recoveryStarted = false;
    Object? streamError;

    _driverSubscription = channel.stream.listen(
      (message) =>
          _forwardMessage(message, _driverMessageController, role: 'driver'),
      onError: (Object error) {
        if (!identical(_driverSocket, channel)) return;
        streamTerminated = true;
        streamError = error;
        _driverConnected = false;
        if (ready && !recoveryStarted) {
          recoveryStarted = true;
          unawaited(_recoverDriverSocket(channel, error, token: token));
        }
      },
      onDone: () {
        if (!identical(_driverSocket, channel)) return;
        streamTerminated = true;
        final closed = _SocketClosed(channel.closeCode, channel.closeReason);
        streamError ??= closed;
        _driverConnected = false;
        if (ready && !recoveryStarted) {
          recoveryStarted = true;
          unawaited(
            _recoverDriverSocket(
              channel,
              closed,
              token: token,
              closeCode: channel.closeCode,
              closeReason: channel.closeReason,
            ),
          );
        }
      },
      cancelOnError: false,
    );

    try {
      await channel.ready.timeout(_connectionTimeout);
      if (!identical(_driverSocket, channel) || streamTerminated) {
        throw streamError ??
            StateError('Driver WebSocket closed during connection');
      }

      ready = true;
      final recovered = isRecovery || _driverReconnectAttempts > 0;
      _driverConnected = true;
      _driverReconnectAttempts = 0;
      _driverRecoveryProbeTimer?.cancel();
      _driverRecoveryProbeTimer = null;
      _scheduleDriverTokenRefresh(token);
      _setDriverStatus(WebSocketConnectionStatus.connected);
      Logger.websocket('Driver WebSocket connected');
      if (recovered && !_driverReconnectController.isClosed) {
        _driverReconnectController.add(null);
      }
    } catch (error, stackTrace) {
      _driverConnected = false;
      if (identical(_driverSocket, channel) && !recoveryStarted) {
        recoveryStarted = true;
        await _recoverDriverSocket(
          channel,
          streamError ?? error,
          token: token,
          closeCode: channel.closeCode,
          closeReason: channel.closeReason,
        );
      }
      Error.throwWithStackTrace(
        const _WebSocketConnectionException(
          'Unable to establish driver WebSocket connection',
        ),
        stackTrace,
      );
    }
  }

  bool sendPassengerMessage(Map<String, dynamic> message) {
    if (!isPassengerConnected) {
      Logger.warning(
        'Cannot send passenger message: socket not connected',
        tag: 'WebSocket',
      );
      return false;
    }

    try {
      _passengerSocket!.sink.add(json.encode(message));
      return true;
    } catch (error) {
      Logger.error(
        'Error sending passenger message',
        error: _redactError(error, _passengerJwtToken),
        tag: 'WebSocket',
      );
      return false;
    }
  }

  bool sendDriverMessage(Map<String, dynamic> message) {
    if (!isDriverConnected) {
      Logger.warning(
        'Cannot send driver message: socket not connected',
        tag: 'WebSocket',
      );
      return false;
    }

    try {
      _driverSocket!.sink.add(json.encode(message));
      return true;
    } catch (error) {
      Logger.error(
        'Error sending driver message',
        error: _redactError(error, _driverJwtToken),
        tag: 'WebSocket',
      );
      return false;
    }
  }

  void disconnectPassenger() {
    _passengerJwtToken = null;
    _passengerReconnectTimer?.cancel();
    _passengerReconnectTimer = null;
    _passengerTokenRefreshTimer?.cancel();
    _passengerTokenRefreshTimer = null;
    _passengerRecoveryProbeTimer?.cancel();
    _passengerRecoveryProbeTimer = null;
    _passengerReconnectAttempts = 0;
    _passengerConnected = false;
    _setPassengerStatus(WebSocketConnectionStatus.disconnected);

    final subscription = _passengerSubscription;
    final socket = _passengerSocket;
    _passengerConnectFuture = null;
    _passengerSubscription = null;
    _passengerSocket = null;
    unawaited(subscription?.cancel());
    unawaited(_closeQuietly(socket));
    Logger.websocket('Passenger WebSocket disconnected');
  }

  void disconnectDriver() {
    _driverJwtToken = null;
    _driverReconnectTimer?.cancel();
    _driverReconnectTimer = null;
    _driverTokenRefreshTimer?.cancel();
    _driverTokenRefreshTimer = null;
    _driverRecoveryProbeTimer?.cancel();
    _driverRecoveryProbeTimer = null;
    _driverReconnectAttempts = 0;
    _driverConnected = false;
    _setDriverStatus(WebSocketConnectionStatus.disconnected);

    final subscription = _driverSubscription;
    final socket = _driverSocket;
    _driverConnectFuture = null;
    _driverSubscription = null;
    _driverSocket = null;
    unawaited(subscription?.cancel());
    unawaited(_closeQuietly(socket));
    Logger.websocket('Driver WebSocket disconnected');
  }

  void disconnectAll() {
    disconnectPassenger();
    disconnectDriver();
  }

  Future<void> _recoverPassengerSocket(
    WebSocketChannel channel,
    Object error, {
    required String token,
    int? closeCode,
    String? closeReason,
  }) async {
    if (!identical(_passengerSocket, channel)) return;

    final subscription = _passengerSubscription;
    _passengerSubscription = null;
    _passengerSocket = null;
    _passengerConnected = false;
    _setPassengerStatus(WebSocketConnectionStatus.reconnecting);
    _passengerTokenRefreshTimer?.cancel();
    _passengerTokenRefreshTimer = null;
    await subscription?.cancel();
    await _closeQuietly(channel);

    Logger.warning(
      'Passenger WebSocket disconnected: ${_redactError(error, token)}',
      tag: 'WebSocket',
    );
    if (_isAuthenticationFailure(error, closeCode, closeReason)) {
      await _refreshPassengerToken(token);
    }
    _schedulePassengerReconnect();
  }

  Future<void> _recoverDriverSocket(
    WebSocketChannel channel,
    Object error, {
    required String token,
    int? closeCode,
    String? closeReason,
  }) async {
    if (!identical(_driverSocket, channel)) return;

    final subscription = _driverSubscription;
    _driverSubscription = null;
    _driverSocket = null;
    _driverConnected = false;
    _setDriverStatus(WebSocketConnectionStatus.reconnecting);
    _driverTokenRefreshTimer?.cancel();
    _driverTokenRefreshTimer = null;
    await subscription?.cancel();
    await _closeQuietly(channel);

    Logger.warning(
      'Driver WebSocket disconnected: ${_redactError(error, token)}',
      tag: 'WebSocket',
    );
    if (_isAuthenticationFailure(error, closeCode, closeReason)) {
      await _refreshDriverToken(token);
    }
    _scheduleDriverReconnect();
  }

  void _schedulePassengerReconnect() {
    if (_passengerReconnectTimer != null || _passengerJwtToken == null) return;
    if (_passengerReconnectAttempts >= _maxReconnectAttempts) {
      _setPassengerStatus(WebSocketConnectionStatus.failed);
      Logger.warning(
        'Max passenger reconnect attempts reached',
        tag: 'WebSocket',
      );
      _passengerRecoveryProbeTimer ??= Timer(_maxReconnectDelay, () {
        _passengerRecoveryProbeTimer = null;
        unawaited(_attemptPassengerReconnect());
      });
      return;
    }

    _setPassengerStatus(WebSocketConnectionStatus.reconnecting);
    _passengerReconnectAttempts++;
    final attempt = _passengerReconnectAttempts;
    final delay = _reconnectDelay(attempt);
    Logger.websocket(
      'Scheduling passenger reconnect attempt $attempt in '
      '${delay.inMilliseconds}ms',
    );

    _passengerReconnectTimer = Timer(delay, () {
      _passengerReconnectTimer = null;
      unawaited(_attemptPassengerReconnect());
    });
  }

  Future<void> _attemptPassengerReconnect() async {
    if (_passengerJwtToken == null || isPassengerConnected) return;
    try {
      await _connectPassenger(isRecovery: true);
    } catch (error) {
      Logger.warning(
        'Passenger reconnect attempt failed: '
        '${_redactError(error, _passengerJwtToken)}',
        tag: 'WebSocket',
      );
    }
  }

  void _scheduleDriverReconnect() {
    if (_driverReconnectTimer != null || _driverJwtToken == null) return;
    if (_driverReconnectAttempts >= _maxReconnectAttempts) {
      _setDriverStatus(WebSocketConnectionStatus.failed);
      Logger.warning('Max driver reconnect attempts reached', tag: 'WebSocket');
      _driverRecoveryProbeTimer ??= Timer(_maxReconnectDelay, () {
        _driverRecoveryProbeTimer = null;
        unawaited(_attemptDriverReconnect());
      });
      return;
    }

    _setDriverStatus(WebSocketConnectionStatus.reconnecting);
    _driverReconnectAttempts++;
    final attempt = _driverReconnectAttempts;
    final delay = _reconnectDelay(attempt);
    Logger.websocket(
      'Scheduling driver reconnect attempt $attempt in '
      '${delay.inMilliseconds}ms',
    );

    _driverReconnectTimer = Timer(delay, () {
      _driverReconnectTimer = null;
      unawaited(_attemptDriverReconnect());
    });
  }

  Future<void> _attemptDriverReconnect() async {
    if (_driverJwtToken == null || isDriverConnected) return;
    try {
      await _connectDriver(isRecovery: true);
    } catch (error) {
      Logger.warning(
        'Driver reconnect attempt failed: '
        '${_redactError(error, _driverJwtToken)}',
        tag: 'WebSocket',
      );
    }
  }

  Duration _reconnectDelay(int attempt) {
    final exponential =
        _baseReconnectDelay.inMilliseconds * pow(2, attempt - 1).toInt();
    final capped = min(exponential, _maxReconnectDelay.inMilliseconds);
    final jitter = 0.8 + (_random.nextDouble() * 0.4);
    return Duration(milliseconds: max(1, (capped * jitter).round()));
  }

  Future<String> _freshTokenIfNeeded(String token) async {
    if (!_isJwtExpiring(token)) return token;

    final refreshed = await AuthService().refreshAccessToken(
      reconnectWebSockets: false,
    );
    final newToken = await AuthService().getAccessToken();
    if (!refreshed || newToken == null || newToken.isEmpty) {
      throw StateError('Unable to refresh the expired WebSocket access token');
    }
    return newToken;
  }

  void _schedulePassengerTokenRefresh(String token) {
    _passengerTokenRefreshTimer?.cancel();
    final expiry = _jwtExpiry(token);
    if (expiry == null) return;
    final delay = expiry.difference(
      DateTime.now().toUtc().add(_tokenRefreshWindow),
    );
    _passengerTokenRefreshTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_refreshPassengerBeforeExpiry(token)),
    );
  }

  void _scheduleDriverTokenRefresh(String token) {
    _driverTokenRefreshTimer?.cancel();
    final expiry = _jwtExpiry(token);
    if (expiry == null) return;
    final delay = expiry.difference(
      DateTime.now().toUtc().add(_tokenRefreshWindow),
    );
    _driverTokenRefreshTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_refreshDriverBeforeExpiry(token)),
    );
  }

  Future<void> _refreshPassengerBeforeExpiry(String expiringToken) async {
    _passengerTokenRefreshTimer = null;
    if (!isPassengerConnected || _passengerJwtToken != expiringToken) return;

    final refreshed = await AuthService().refreshAccessToken(
      reconnectWebSockets: false,
    );
    if (_passengerJwtToken != expiringToken) return;
    final token = await AuthService().getAccessToken();
    if (!refreshed ||
        token == null ||
        token.isEmpty ||
        token == expiringToken) {
      _passengerTokenRefreshTimer = Timer(
        _tokenRefreshRetryDelay,
        () => unawaited(_refreshPassengerBeforeExpiry(expiringToken)),
      );
      return;
    }

    _passengerJwtToken = token;
    await _replacePassengerSocket();
    try {
      await _connectPassenger(isRecovery: true);
    } catch (error) {
      Logger.warning(
        'Passenger WebSocket pre-expiry rotation failed: '
        '${_redactError(error, token)}',
        tag: 'WebSocket',
      );
    }
  }

  Future<void> _refreshDriverBeforeExpiry(String expiringToken) async {
    _driverTokenRefreshTimer = null;
    if (!isDriverConnected || _driverJwtToken != expiringToken) return;

    final refreshed = await AuthService().refreshAccessToken(
      reconnectWebSockets: false,
    );
    if (_driverJwtToken != expiringToken) return;
    final token = await AuthService().getAccessToken();
    if (!refreshed ||
        token == null ||
        token.isEmpty ||
        token == expiringToken) {
      _driverTokenRefreshTimer = Timer(
        _tokenRefreshRetryDelay,
        () => unawaited(_refreshDriverBeforeExpiry(expiringToken)),
      );
      return;
    }

    _driverJwtToken = token;
    await _replaceDriverSocket();
    try {
      await _connectDriver(isRecovery: true);
    } catch (error) {
      Logger.warning(
        'Driver WebSocket pre-expiry rotation failed: '
        '${_redactError(error, token)}',
        tag: 'WebSocket',
      );
    }
  }

  Future<void> _refreshPassengerToken(String failedToken) async {
    if (_passengerJwtToken != failedToken) return;
    final refreshed = await AuthService().refreshAccessToken(
      reconnectWebSockets: false,
    );
    if (!refreshed) return;
    final token = await AuthService().getAccessToken();
    if (token != null && token.isNotEmpty) _passengerJwtToken = token;
  }

  Future<void> _refreshDriverToken(String failedToken) async {
    if (_driverJwtToken != failedToken) return;
    final refreshed = await AuthService().refreshAccessToken(
      reconnectWebSockets: false,
    );
    if (!refreshed) return;
    final token = await AuthService().getAccessToken();
    if (token != null && token.isNotEmpty) _driverJwtToken = token;
  }

  bool _isJwtExpiring(String token) {
    final expiresAt = _jwtExpiry(token);
    if (expiresAt == null) return false;
    return DateTime.now().toUtc().add(_tokenRefreshWindow).isAfter(expiresAt);
  }

  DateTime? _jwtExpiry(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map) return null;
      final exp = payload['exp'];
      final seconds = exp is num ? exp.toInt() : int.tryParse(exp.toString());
      if (seconds == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    } catch (_) {
      return null;
    }
  }

  bool _isAuthenticationFailure(
    Object error,
    int? closeCode,
    String? closeReason,
  ) {
    if (const {4001, 4003, 4401, 4403}.contains(closeCode)) return true;
    final details = '$error ${closeReason ?? ''}'.toLowerCase();
    final mentionsAuthentication =
        details.contains('401') ||
        details.contains('403') ||
        details.contains('unauthor') ||
        details.contains('forbidden') ||
        details.contains('authentication') ||
        details.contains('expired') ||
        details.contains('invalid token') ||
        details.contains('jwt');
    return mentionsAuthentication ||
        (closeCode == 1008 && details.contains('token'));
  }

  void _forwardMessage(
    dynamic message,
    StreamController<Map<String, dynamic>> controller, {
    required String role,
  }) {
    try {
      final decoded = json.decode(message as String);
      if (decoded is! Map) {
        throw const FormatException('WebSocket payload must be a JSON object');
      }
      controller.add(Map<String, dynamic>.from(decoded));
    } catch (error) {
      Logger.error(
        'Error parsing $role WebSocket message',
        error: _redactError(
          error,
          role == 'driver' ? _driverJwtToken : _passengerJwtToken,
        ),
        tag: 'WebSocket',
      );
    }
  }

  String _redactError(Object error, String? token) {
    var text = error.toString();
    if (token != null && token.isNotEmpty) {
      text = text.replaceAll(token, '<redacted>');
    }
    return text.replaceAll(
      RegExp(r'([?&]token=)[^&\s]+', caseSensitive: false),
      r'$1<redacted>',
    );
  }

  Future<void> _closeQuietly(WebSocketChannel? channel) async {
    if (channel == null) return;
    try {
      await channel.sink.close().timeout(_connectionTimeout);
    } catch (_) {
      // The connection may already be closed or unreachable.
    }
  }

  void _setPassengerStatus(WebSocketConnectionStatus status) {
    if (_passengerStatus == status) return;
    _passengerStatus = status;
    if (!_passengerStatusController.isClosed) {
      _passengerStatusController.add(status);
    }
  }

  void _setDriverStatus(WebSocketConnectionStatus status) {
    if (_driverStatus == status) return;
    _driverStatus = status;
    if (!_driverStatusController.isClosed) {
      _driverStatusController.add(status);
    }
  }

  void dispose() {
    disconnectAll();
    _passengerMessageController.close();
    _driverMessageController.close();
    _passengerReconnectController.close();
    _driverReconnectController.close();
    _passengerStatusController.close();
    _driverStatusController.close();
  }
}

class _SocketClosed implements Exception {
  const _SocketClosed(this.code, this.reason);

  final int? code;
  final String? reason;

  @override
  String toString() =>
      'WebSocket closed (code: ${code ?? 'unknown'}, reason: ${reason ?? 'none'})';
}

class _WebSocketConnectionException implements Exception {
  const _WebSocketConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}
