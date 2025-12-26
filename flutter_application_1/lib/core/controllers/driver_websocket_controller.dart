import 'dart:async';
import '../../services/websocket_service.dart';
import '../../services/logger_service.dart';
import 'driver_ride_controller.dart';

/// Controller for handling driver WebSocket messages
class DriverWebSocketController {
  final WebSocketService _wsService = WebSocketService();
  final DriverRideController _rideController = DriverRideController();
  StreamSubscription? _subscription;

  /// Connect to driver WebSocket
  Future<void> connect({
    required String? jwtToken,
    String? sessionId,
    String? csrfToken,
    required Function(Map<String, dynamic>) onMessage,
  }) async {
    try {
      if (jwtToken == null || jwtToken.isEmpty) {
        Logger.warning(
          'Cannot connect WebSocket: no auth token',
          tag: 'DriverWebSocketController',
        );
        return;
      }

      await _wsService.connectDriver(
        jwtToken: jwtToken,
        sessionId: sessionId,
        csrfToken: csrfToken,
      );

      _subscription = _wsService.driverMessages.listen((data) {
        Logger.websocket(
          "DRIVER WS RAW → $data",
          tag: 'DriverWebSocketController',
        );
        onMessage(data);
      });

      Logger.websocket(
        'Driver WebSocket connected via controller',
        tag: 'DriverWebSocketController',
      );
    } catch (e) {
      Logger.error(
        'Failed to connect driver WebSocket',
        error: e,
        tag: 'DriverWebSocketController',
      );
    }
  }

  /// Process WebSocket message and return event type
  String? processMessage(
    Map<String, dynamic> data, {
    required Function(Map<String, dynamic>) onRideOffer,
    required Function(dynamic, String) onRideRemoval,
    required Function(int?) onCurrentRideCleared,
    required bool isActive,
    required Function() stopLocationUpdates,
    required Function() startLocationUpdates,
  }) {
    try {
      final eventType = data['type'] as String?;
      if (eventType == null) return null;

      switch (eventType) {
        case 'connection_established':
          Logger.websocket(
            'Connection established: ${data['message'] ?? 'Connected'}',
            tag: 'DriverWebSocketController',
          );
          break;

        case 'ride_offer':
          final rideData = data['ride'];
          if (rideData is Map) {
            final Map<String, dynamic> rd = Map<String, dynamic>.from(rideData);
            final status = rd['status']?.toString();
            if (status == null || status == 'pending') {
              onRideOffer(rd);
            } else {
              Logger.websocket(
                'Ignoring incoming ride (status=$status): ${rd['id']}',
                tag: 'DriverWebSocketController',
              );
            }
          }
          break;

        case 'ride_cancelled':
        case 'ride_expired':
          final message =
              data['message'] ??
              (eventType == 'ride_cancelled'
                  ? 'Ride cancelled by passenger'
                  : 'Ride offer timed out');
          onRideRemoval(data['ride_id'], message);

          // Handle current ride clearing
          try {
            final incoming = data['ride_id'];
            final int? rid = incoming is int
                ? incoming
                : int.tryParse('$incoming');
            if (rid != null) {
              onCurrentRideCleared(rid);
              if (isActive) {
                stopLocationUpdates();
                startLocationUpdates();
              }
            }
          } catch (_) {}
          break;

        default:
          Logger.warning(
            'Unhandled WS event: $data',
            tag: 'DriverWebSocketController',
          );
      }

      return eventType;
    } catch (e) {
      Logger.error(
        'Error decoding driver WS message: $e | raw=$data',
        tag: 'DriverWebSocketController',
      );
      return null;
    }
  }

  /// Get ride controller for ride operations
  DriverRideController get rideController => _rideController;

  /// Dispose resources
  void dispose() {
    try {
      _subscription?.cancel();
      _subscription = null;
    } catch (e) {
      Logger.error(
        'Error cancelling WebSocket subscription',
        error: e,
        tag: 'DriverWebSocketController',
      );
    }
  }
}
