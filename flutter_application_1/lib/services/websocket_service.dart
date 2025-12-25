import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../utils/ws_utils.dart';
import '../utils/socket_channel_factory.dart';
import '../config/app_constants.dart';
import 'logger_service.dart';

/// Centralized WebSocket service for managing connections
/// Supports both passenger and driver connections
class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _passengerSocket;
  WebSocketChannel? _driverSocket;
  StreamSubscription? _passengerSubscription;
  StreamSubscription? _driverSubscription;

  final _passengerMessageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _driverMessageController =
      StreamController<Map<String, dynamic>>.broadcast();

  bool _passengerConnected = false;
  bool _driverConnected = false;
  Timer? _passengerReconnectTimer;
  Timer? _driverReconnectTimer;
  int _passengerReconnectAttempts = 0;
  int _driverReconnectAttempts = 0;

  // Store auth tokens for reconnection
  String? _passengerJwtToken;
  String? _passengerSessionId;
  String? _passengerCsrfToken;
  String? _driverJwtToken;
  String? _driverSessionId;
  String? _driverCsrfToken;

  static const int _maxReconnectAttempts =
      WebSocketConstants.maxReconnectAttempts;
  static const Duration _baseReconnectDelay =
      WebSocketConstants.baseReconnectDelay;

  /// Get stream of passenger messages
  Stream<Map<String, dynamic>> get passengerMessages =>
      _passengerMessageController.stream;

  /// Get stream of driver messages
  Stream<Map<String, dynamic>> get driverMessages =>
      _driverMessageController.stream;

  /// Check if passenger socket is connected
  bool get isPassengerConnected =>
      _passengerConnected && _passengerSocket != null;

  /// Check if driver socket is connected
  bool get isDriverConnected => _driverConnected && _driverSocket != null;

  /// Connect passenger WebSocket
  Future<void> connectPassenger({
    required String? jwtToken,
    String? sessionId,
    String? csrfToken,
  }) async {
    // Store tokens for reconnection
    _passengerJwtToken = jwtToken;
    _passengerSessionId = sessionId;
    _passengerCsrfToken = csrfToken;

    if (_passengerConnected && _passengerSocket != null) {
      Logger.websocket('Passenger WebSocket already connected');
      return;
    }

    // Cancel any pending reconnection attempts
    _passengerReconnectTimer?.cancel();
    _passengerReconnectTimer = null;

    try {
      final queryParams = <String, String>{};
      if (jwtToken != null && jwtToken.isNotEmpty) {
        queryParams['token'] = jwtToken;
      }
      if (sessionId != null && sessionId.isNotEmpty) {
        queryParams['sessionid'] = sessionId;
      }
      if (csrfToken != null && csrfToken.isNotEmpty) {
        queryParams['csrftoken'] = csrfToken;
      }

      final uri = buildWsUri('/ws/app/', queryParams: queryParams);
      _passengerSocket = createPlatformWebSocket(uri);

      _passengerSubscription = _passengerSocket!.stream.listen(
        (message) {
          try {
            final data = json.decode(message) as Map<String, dynamic>;
            _passengerMessageController.add(data);
          } catch (e) {
            Logger.error(
              'Error parsing passenger WebSocket message',
              error: e,
              tag: 'WebSocket',
            );
          }
        },
        onError: (error) {
          Logger.error(
            'Passenger WebSocket error',
            error: error,
            tag: 'WebSocket',
          );
          _handlePassengerError(error);
        },
        onDone: () {
          Logger.websocket('Passenger WebSocket connection closed');
          _handlePassengerDisconnect();
        },
        cancelOnError: false,
      );

      _passengerConnected = true;
      _passengerReconnectAttempts = 0;
      Logger.websocket('Passenger WebSocket connected: $uri');
    } catch (e) {
      Logger.error(
        'Failed to connect passenger WebSocket',
        error: e,
        tag: 'WebSocket',
      );
      _handlePassengerError(e);
    }
  }

  /// Connect driver WebSocket
  Future<void> connectDriver({
    required String? jwtToken,
    String? sessionId,
    String? csrfToken,
  }) async {
    // Store tokens for reconnection
    _driverJwtToken = jwtToken;
    _driverSessionId = sessionId;
    _driverCsrfToken = csrfToken;

    if (_driverConnected && _driverSocket != null) {
      Logger.websocket('Driver WebSocket already connected');
      return;
    }

    // Cancel any pending reconnection attempts
    _driverReconnectTimer?.cancel();
    _driverReconnectTimer = null;

    try {
      final queryParams = <String, String>{};
      if (jwtToken != null && jwtToken.isNotEmpty) {
        queryParams['token'] = jwtToken;
      }
      if (sessionId != null && sessionId.isNotEmpty) {
        queryParams['sessionid'] = sessionId;
      }
      if (csrfToken != null && csrfToken.isNotEmpty) {
        queryParams['csrftoken'] = csrfToken;
      }

      final uri = buildWsUri('/ws/app/', queryParams: queryParams);
      _driverSocket = createPlatformWebSocket(uri);

      _driverSubscription = _driverSocket!.stream.listen(
        (message) {
          try {
            final data = json.decode(message) as Map<String, dynamic>;
            _driverMessageController.add(data);
          } catch (e) {
            Logger.error(
              'Error parsing driver WebSocket message',
              error: e,
              tag: 'WebSocket',
            );
          }
        },
        onError: (error) {
          Logger.error(
            'Driver WebSocket error',
            error: error,
            tag: 'WebSocket',
          );
          _handleDriverError(error);
        },
        onDone: () {
          Logger.websocket('Driver WebSocket connection closed');
          _handleDriverDisconnect();
        },
        cancelOnError: false,
      );

      _driverConnected = true;
      _driverReconnectAttempts = 0;
      Logger.websocket('Driver WebSocket connected: $uri');
    } catch (e) {
      Logger.error(
        'Failed to connect driver WebSocket',
        error: e,
        tag: 'WebSocket',
      );
      _handleDriverError(e);
    }
  }

  /// Send message via passenger socket
  void sendPassengerMessage(Map<String, dynamic> message) {
    if (_passengerSocket != null && _passengerConnected) {
      try {
        _passengerSocket!.sink.add(json.encode(message));
      } catch (e) {
        Logger.error(
          'Error sending passenger message',
          error: e,
          tag: 'WebSocket',
        );
      }
    } else {
      Logger.warning(
        'Cannot send passenger message: socket not connected',
        tag: 'WebSocket',
      );
    }
  }

  /// Send message via driver socket
  void sendDriverMessage(Map<String, dynamic> message) {
    if (_driverSocket != null && _driverConnected) {
      try {
        _driverSocket!.sink.add(json.encode(message));
      } catch (e) {
        Logger.error(
          'Error sending driver message',
          error: e,
          tag: 'WebSocket',
        );
      }
    } else {
      Logger.warning(
        'Cannot send driver message: socket not connected',
        tag: 'WebSocket',
      );
    }
  }

  /// Disconnect passenger WebSocket
  void disconnectPassenger() {
    // Clear stored tokens
    _passengerJwtToken = null;
    _passengerSessionId = null;
    _passengerCsrfToken = null;

    try {
      _passengerReconnectTimer?.cancel();
      _passengerReconnectTimer = null;
    } catch (e) {
      Logger.error(
        'Error cancelling passenger reconnect timer',
        error: e,
        tag: 'WebSocket',
      );
    }

    try {
      _passengerSubscription?.cancel();
      _passengerSubscription = null;
    } catch (e) {
      Logger.error(
        'Error cancelling passenger subscription',
        error: e,
        tag: 'WebSocket',
      );
    }

    try {
      _passengerSocket?.sink.close();
      _passengerSocket = null;
    } catch (e) {
      Logger.error(
        'Error closing passenger socket',
        error: e,
        tag: 'WebSocket',
      );
    }

    _passengerConnected = false;
    _passengerReconnectAttempts = 0;
    Logger.websocket('Passenger WebSocket disconnected');
  }

  /// Disconnect driver WebSocket
  void disconnectDriver() {
    // Clear stored tokens
    _driverJwtToken = null;
    _driverSessionId = null;
    _driverCsrfToken = null;

    try {
      _driverReconnectTimer?.cancel();
      _driverReconnectTimer = null;
    } catch (e) {
      Logger.error(
        'Error cancelling driver reconnect timer',
        error: e,
        tag: 'WebSocket',
      );
    }

    try {
      _driverSubscription?.cancel();
      _driverSubscription = null;
    } catch (e) {
      Logger.error(
        'Error cancelling driver subscription',
        error: e,
        tag: 'WebSocket',
      );
    }

    try {
      _driverSocket?.sink.close();
      _driverSocket = null;
    } catch (e) {
      Logger.error('Error closing driver socket', error: e, tag: 'WebSocket');
    }

    _driverConnected = false;
    _driverReconnectAttempts = 0;
    Logger.websocket('Driver WebSocket disconnected');
  }

  /// Disconnect all WebSockets
  void disconnectAll() {
    disconnectPassenger();
    disconnectDriver();
  }

  void _handlePassengerError(dynamic error) {
    _passengerConnected = false;
    _schedulePassengerReconnect();
  }

  void _handlePassengerDisconnect() {
    _passengerConnected = false;
    _schedulePassengerReconnect();
  }

  void _schedulePassengerReconnect() {
    if (_passengerReconnectAttempts >= _maxReconnectAttempts) {
      Logger.warning(
        'Max passenger reconnect attempts reached',
        tag: 'WebSocket',
      );
      return;
    }

    // Check if we have tokens to reconnect
    if (_passengerJwtToken == null) {
      Logger.warning(
        'Cannot reconnect passenger: no auth tokens stored',
        tag: 'WebSocket',
      );
      return;
    }

    _passengerReconnectTimer?.cancel();
    _passengerReconnectAttempts++;

    // Exponential backoff: 2s, 4s, 8s, 16s, 32s
    final delay = Duration(
      milliseconds:
          _baseReconnectDelay.inMilliseconds *
          pow(2, _passengerReconnectAttempts - 1).toInt(),
    );

    Logger.websocket(
      'Scheduling passenger reconnect attempt $_passengerReconnectAttempts in ${delay.inSeconds}s',
    );

    _passengerReconnectTimer = Timer(delay, () async {
      Logger.websocket('Attempting passenger reconnection...');
      // Disconnect existing socket if any
      try {
        _passengerSubscription?.cancel();
        _passengerSocket?.sink.close();
      } catch (e) {
        Logger.debug(
          'Error cleaning up old passenger socket: $e',
          tag: 'WebSocket',
        );
      }

      _passengerSocket = null;
      _passengerSubscription = null;
      _passengerConnected = false;

      // Attempt reconnection with stored tokens
      await connectPassenger(
        jwtToken: _passengerJwtToken,
        sessionId: _passengerSessionId,
        csrfToken: _passengerCsrfToken,
      );
    });
  }

  void _handleDriverError(dynamic error) {
    _driverConnected = false;
    _scheduleDriverReconnect();
  }

  void _handleDriverDisconnect() {
    _driverConnected = false;
    _scheduleDriverReconnect();
  }

  void _scheduleDriverReconnect() {
    if (_driverReconnectAttempts >= _maxReconnectAttempts) {
      Logger.warning('Max driver reconnect attempts reached', tag: 'WebSocket');
      return;
    }

    // Check if we have tokens to reconnect
    if (_driverJwtToken == null) {
      Logger.warning(
        'Cannot reconnect driver: no auth tokens stored',
        tag: 'WebSocket',
      );
      return;
    }

    _driverReconnectTimer?.cancel();
    _driverReconnectAttempts++;

    // Exponential backoff: 2s, 4s, 8s, 16s, 32s
    final delay = Duration(
      milliseconds:
          _baseReconnectDelay.inMilliseconds *
          pow(2, _driverReconnectAttempts - 1).toInt(),
    );

    Logger.websocket(
      'Scheduling driver reconnect attempt $_driverReconnectAttempts in ${delay.inSeconds}s',
    );

    _driverReconnectTimer = Timer(delay, () async {
      Logger.websocket('Attempting driver reconnection...');
      // Disconnect existing socket if any
      try {
        _driverSubscription?.cancel();
        _driverSocket?.sink.close();
      } catch (e) {
        Logger.debug(
          'Error cleaning up old driver socket: $e',
          tag: 'WebSocket',
        );
      }

      _driverSocket = null;
      _driverSubscription = null;
      _driverConnected = false;

      // Attempt reconnection with stored tokens
      await connectDriver(
        jwtToken: _driverJwtToken,
        sessionId: _driverSessionId,
        csrfToken: _driverCsrfToken,
      );
    });
  }

  /// Cleanup all resources
  void dispose() {
    disconnectAll();
    _passengerMessageController.close();
    _driverMessageController.close();
  }
}
