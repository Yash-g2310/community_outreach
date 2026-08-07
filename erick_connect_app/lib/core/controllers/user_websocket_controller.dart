import 'dart:async';
import '../../services/websocket_service.dart';
import '../../services/logger_service.dart';

/// Controller for handling user/passenger WebSocket messages
class UserWebSocketController {
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription? _subscription;
  StreamSubscription<void>? _reconnectSubscription;
  final Set<String> _processedRideEvents = <String>{};

  /// Connect to passenger WebSocket
  Future<void> connect({
    required String? jwtToken,
    required Function(Map<String, dynamic>) onMessage,
    Future<void> Function()? onReconnect,
  }) async {
    try {
      if (jwtToken == null || jwtToken.isEmpty) {
        Logger.warning(
          'Cannot connect WebSocket: no auth token',
          tag: 'UserWebSocketController',
        );
        return;
      }

      await _subscription?.cancel();
      _subscription = _wsService.passengerMessages.listen((data) {
        Logger.websocket("WS RAW → $data", tag: 'UserWebSocketController');
        onMessage(data);
      });
      await _reconnectSubscription?.cancel();
      _reconnectSubscription = onReconnect == null
          ? null
          : _wsService.passengerReconnected.listen((_) {
              unawaited(onReconnect());
            });

      await _wsService.connectPassenger(jwtToken: jwtToken);

      Logger.websocket(
        'Passenger WebSocket connected via controller',
        tag: 'UserWebSocketController',
      );
    } catch (e) {
      Logger.error(
        'Failed to connect passenger WebSocket',
        error: e,
        tag: 'UserWebSocketController',
      );
    }
  }

  /// Check if event should be processed (deduplication)
  bool shouldProcessEvent(Map<String, dynamic> data) {
    final eventType = data['type'] as String?;
    if (eventType == null) return false;

    // Only dedupe ride-related events
    if (eventType.startsWith("ride_")) {
      final rideIdKey = data['ride_id']?.toString() ?? '';
      final dedupeKey = '${eventType}_$rideIdKey';

      if (_processedRideEvents.contains(dedupeKey)) {
        return false;
      }
      _processedRideEvents.add(dedupeKey);
    }

    return true;
  }

  /// Dispose resources
  void dispose() {
    try {
      _subscription?.cancel();
      _subscription = null;
      _reconnectSubscription?.cancel();
      _reconnectSubscription = null;
    } catch (e) {
      Logger.error(
        'Error cancelling WebSocket subscription',
        error: e,
        tag: 'UserWebSocketController',
      );
    }
  }
}
