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
  LatLng? _latestLocation;

  static const _minimumInterval = Duration(seconds: 5);

  Future<LatLng?> start({
    required RideId rideId,
    required void Function(LatLng location) onLocation,
  }) async {
    _rideId = rideId;
    final initialLocation = await _locationService.getCurrentLocation();
    if (initialLocation != null) {
      _latestLocation = initialLocation;
      onLocation(initialLocation);
      _publish(initialLocation);
    }

    final stream = _locationService.getLocationStream();
    if (stream == null) return initialLocation;
    await _subscription?.cancel();
    _subscription = stream.listen(
      (location) {
        _latestLocation = location;
        onLocation(location);
        _publish(location);
      },
      onError: (Object error) {
        Logger.error(
          'Ride location stream failed',
          error: error,
          tag: 'RideLocationPublisher',
        );
      },
    );
    return initialLocation;
  }

  /// Sends the newest known position immediately after socket recovery.
  void republishLatest() {
    final location = _latestLocation;
    if (location != null) _publish(location, force: true);
  }

  void _publish(LatLng location, {bool force = false}) {
    final rideId = _rideId;
    if (rideId == null) return;
    final now = DateTime.now().toUtc();
    if (!force &&
        _lastSentAt != null &&
        now.difference(_lastSentAt!) < _minimumInterval) {
      return;
    }
    final message = {
      'type': role == 'driver'
          ? 'driver_location_update'
          : 'rider_location_update',
      'ride_id': rideId,
      'latitude': double.parse(location.latitude.toStringAsFixed(6)),
      'longitude': double.parse(location.longitude.toStringAsFixed(6)),
      'timestamp': now.toIso8601String(),
    };
    final sent = role == 'driver'
        ? _webSocketService.sendDriverMessage(message)
        : _webSocketService.sendPassengerMessage(message);
    if (sent) _lastSentAt = now;
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _rideId = null;
    _latestLocation = null;
    _lastSentAt = null;
  }
}
