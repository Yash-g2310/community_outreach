import 'dart:async';

import '../../services/logger_service.dart';
import '../../services/websocket_service.dart';
import 'driver_ride_controller.dart';

/// Routes FastAPI driver WebSocket events into the driver-request UI.
class DriverWebSocketController {
  final WebSocketService _wsService = WebSocketService();
  final DriverRideController _rideController = DriverRideController();
  StreamSubscription? _subscription;
  StreamSubscription<void>? _reconnectSubscription;

  Future<void> connect({
    required String? jwtToken,
    required void Function(Map<String, dynamic>) onMessage,
    Future<void> Function()? onReconnect,
  }) async {
    if (jwtToken == null || jwtToken.isEmpty) {
      Logger.warning(
        'Cannot connect WebSocket: no auth token',
        tag: 'DriverWebSocketController',
      );
      return;
    }

    try {
      await _subscription?.cancel();
      _subscription = _wsService.driverMessages.listen((data) {
        Logger.websocket(
          'DRIVER WS RAW -> $data',
          tag: 'DriverWebSocketController',
        );
        onMessage(data);
      });
      await _reconnectSubscription?.cancel();
      _reconnectSubscription = onReconnect == null
          ? null
          : _wsService.driverReconnected.listen((_) {
              unawaited(onReconnect());
            });
      await _wsService.connectDriver(jwtToken: jwtToken);
    } catch (error) {
      Logger.error(
        'Failed to connect driver WebSocket',
        error: error,
        tag: 'DriverWebSocketController',
      );
    }
  }

  void processMessage(
    Map<String, dynamic> data, {
    required void Function(Map<String, dynamic>) onRideOffer,
    required void Function(String rideId, String reason) onRideRemoval,
  }) {
    final eventType = data['type']?.toString();
    switch (eventType) {
      case 'connection.ready':
        Logger.websocket(
          'Driver FastAPI socket ready',
          tag: 'DriverWebSocketController',
        );
        break;
      case 'ride_request':
        onRideOffer(data);
        break;
      case 'ride_request_closed':
        final rideId = data['ride_id']?.toString();
        if (rideId != null && rideId.isNotEmpty) {
          onRideRemoval(
            rideId,
            _closedRequestMessage(data['reason']?.toString()),
          );
        }
        break;
      default:
        // Tracking events are migrated in Stage 4; do not treat them as offers.
        Logger.debug(
          'Ignoring driver WS event: $eventType',
          tag: 'DriverWebSocketController',
        );
    }
  }

  String _closedRequestMessage(String? reason) {
    switch (reason) {
      case 'cancelled_by_rider':
        return 'Ride request was cancelled by the rider.';
      case 'accepted_by_another_driver':
        return 'Ride request was accepted by another driver.';
      case 'no_driver_accepted':
        return 'Ride request expired.';
      default:
        return 'Ride request is no longer available.';
    }
  }

  DriverRideController get rideController => _rideController;

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _reconnectSubscription?.cancel();
    _reconnectSubscription = null;
  }
}
