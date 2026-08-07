import 'dart:async';

import 'package:latlong2/latlong.dart';

import '../../models/ride_id.dart';
import '../../services/location_service.dart';
import '../../services/logger_service.dart';
import '../../services/websocket_service.dart';

/// Shares only the signed-in participant's live location for one active ride.
///
/// FastAPI validates the ride, participant, timestamp, and state on every
/// message. This publisher is deliberately page-scoped so sharing stops as
/// soon as the active-tracking screen is disposed or the ride becomes terminal.
class RideLocationPublisher {
  RideLocationPublisher({required this.role});

  final String role;
  final LocationService _locationService = LocationService();
  final WebSocketService _webSocketService = WebSocketService();
  StreamSubscription<LatLng>? _subscription;
  DateTime? _lastSentAt;
  RideId? _rideId;

  static const _minimumInterval = Duration(seconds: 5);

  Future<LatLng?> start({
    required RideId rideId,
    required void Function(LatLng location) onLocation,
  }) async {
    _rideId = rideId;
    final initialLocation = await _locationService.getCurrentLocation();
    if (initialLocation != null) {
      onLocation(initialLocation);
      _publish(initialLocation);
    }

    final stream = _locationService.getLocationStream();
    if (stream == null) return initialLocation;
    await _subscription?.cancel();
    _subscription = stream.listen(
      (location) {
        onLocation(location);
        _publish(location);
      },
      onError: (Object error) {
        Logger.error('Ride location stream failed', error: error, tag: 'RideLocationPublisher');
      },
    );
    return initialLocation;
  }

  void _publish(LatLng location) {
    final rideId = _rideId;
    if (rideId == null) return;
    final now = DateTime.now().toUtc();
    if (_lastSentAt != null && now.difference(_lastSentAt!) < _minimumInterval) {
      return;
    }
    _lastSentAt = now;
    final message = {
      'type': role == 'driver' ? 'driver_location_update' : 'rider_location_update',
      'ride_id': rideId,
      'latitude': double.parse(location.latitude.toStringAsFixed(6)),
      'longitude': double.parse(location.longitude.toStringAsFixed(6)),
      'timestamp': now.toIso8601String(),
    };
    if (role == 'driver') {
      _webSocketService.sendDriverMessage(message);
    } else {
      _webSocketService.sendPassengerMessage(message);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _rideId = null;
  }
}
