import 'dart:async';
import 'package:latlong2/latlong.dart';
import '../../services/websocket_service.dart';
import '../../services/logger_service.dart';

/// Controller for managing user page WebSocket and state logic
/// Extracts business logic from UserMapScreen
class UserPageController {
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription? _wsSubscription;
  final Set<String> _processedRideEvents = <String>{};

  /// Connect to passenger WebSocket for ride status updates
  Future<void> connectPassengerSocket({
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
          tag: 'UserPageController',
        );
        return;
      }

      // Connect using centralized WebSocket service
      await _wsService.connectPassenger(
        jwtToken: jwtToken,
        sessionId: sessionId,
        csrfToken: csrfToken,
      );

      // Subscribe to passenger messages
      _wsSubscription = _wsService.passengerMessages.listen((data) {
        Logger.websocket("WS RAW → $data", tag: 'UserPageController');
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
          tag: 'UserPageController',
        );
      } else {
        Logger.warning(
          "Cannot subscribe_nearby — currentPosition is null",
          tag: 'UserPageController',
        );
      }

      Logger.websocket(
        'Passenger WebSocket connected via service',
        tag: 'UserPageController',
      );
    } catch (e) {
      Logger.error(
        'Failed to connect passenger WebSocket',
        error: e,
        tag: 'UserPageController',
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
      _wsSubscription?.cancel();
      _wsSubscription = null;
    } catch (e) {
      Logger.error(
        'Error cancelling WebSocket subscription',
        error: e,
        tag: 'UserPageController',
      );
    }
  }
}
