import 'dart:async';
import 'package:latlong2/latlong.dart';
import '../../services/websocket_service.dart';
import '../../services/logger_service.dart';

/// Controller for handling user/passenger WebSocket messages
class UserWebSocketController {
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription? _subscription;
  final Set<String> _processedRideEvents = <String>{};

  /// Connect to passenger WebSocket
  Future<void> connect({
    required String? jwtToken,
    String? sessionId,
    String? csrfToken,
    LatLng? currentPosition,
    required Function(Map<String, dynamic>) onMessage,
  }) async {
    try {
      if (jwtToken == null || jwtToken.isEmpty) {
        Logger.warning(
          'Cannot connect WebSocket: no auth token',
          tag: 'UserWebSocketController',
        );
        return;
      }

      await _wsService.connectPassenger(
        jwtToken: jwtToken,
        sessionId: sessionId,
        csrfToken: csrfToken,
      );

      _subscription = _wsService.passengerMessages.listen((data) {
        Logger.websocket("WS RAW → $data", tag: 'UserWebSocketController');
        onMessage(data);
      });

      // Subscribe to nearby drivers if we have current position
      if (currentPosition != null) {
        _wsService.sendPassengerMessage({
          "type": "subscribe_nearby",
          "latitude": currentPosition.latitude,
          "longitude": currentPosition.longitude,
          "radius": 1500,
        });
        Logger.websocket(
          "Sent Websocket for Nearby Drivers to backend",
          tag: 'UserWebSocketController',
        );
      } else {
        Logger.warning(
          "Cannot subscribe_nearby — currentPosition is null",
          tag: 'UserWebSocketController',
        );
      }

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
    } catch (e) {
      Logger.error(
        'Error cancelling WebSocket subscription',
        error: e,
        tag: 'UserWebSocketController',
      );
    }
  }
}
