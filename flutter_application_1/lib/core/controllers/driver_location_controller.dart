import 'dart:async';
import 'package:latlong2/latlong.dart';
import '../../services/location_service.dart';
import '../../services/websocket_service.dart';
import '../../services/logger_service.dart';

/// Controller for managing driver location updates
/// Extracts location tracking logic from DriverPage
class DriverLocationController {
  final LocationService _locationService = LocationService();
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription<LatLng>? _positionStreamSubscription;
  LatLng? _currentPosition;
  bool _isActive = false;
  int? _currentRideId;

  /// Start location updates
  void startLocationUpdates({
    required bool isActive,
    required Function(LatLng) onLocationUpdate,
  }) {
    if (!isActive) {
      Logger.debug(
        'Not starting location updates: driver is offline',
        tag: 'DriverLocationController',
      );
      return;
    }

    _isActive = isActive;

    // Cancel any existing stream subscription
    _positionStreamSubscription?.cancel();

    // Use LocationService for consistent location handling
    final locationStream = _locationService.getLocationStream();
    if (locationStream == null) {
      Logger.error(
        'Failed to get location stream from LocationService',
        tag: 'DriverLocationController',
      );
      return;
    }

    _positionStreamSubscription = locationStream.listen(
      (LatLng location) async {
        if (!_isActive) return;
        _currentPosition = location;
        await _sendLocationToServer(location);
        onLocationUpdate(location);
      },
      onError: (error) {
        Logger.error(
          'Error in location stream',
          error: error,
          tag: 'DriverLocationController',
        );
      },
    );

    Logger.debug(
      'Location update stream started via LocationService',
      tag: 'DriverLocationController',
    );
  }

  /// Stop location updates
  void stopLocationUpdates() {
    try {
      _positionStreamSubscription?.cancel();
      _positionStreamSubscription = null;
      _isActive = false;
    } catch (e) {
      Logger.error(
        'Error cancelling position stream subscription',
        error: e,
        tag: 'DriverLocationController',
      );
    }

    Logger.debug(
      'Location update stream stopped',
      tag: 'DriverLocationController',
    );
  }

  /// Set current ride ID for tracking updates
  void setCurrentRideId(int? rideId) {
    _currentRideId = rideId;
  }

  /// Set active status
  void setActive(bool active) {
    _isActive = active;
  }

  /// Get current position
  LatLng? get currentPosition => _currentPosition;

  /// Send location to server via WebSocket
  Future<void> _sendLocationToServer(LatLng location) async {
    // Check if WebSocket is connected before sending
    if (!_wsService.isDriverConnected) {
      Logger.debug(
        'Skipping location update: WebSocket not connected yet',
        tag: 'DriverLocationController',
      );
      return;
    }

    try {
      double truncatedLatitude = double.parse(
        location.latitude.toStringAsFixed(6),
      );
      double truncatedLongitude = double.parse(
        location.longitude.toStringAsFixed(6),
      );

      if (_currentRideId != null) {
        Logger.websocket(
          'Sending Tracking Update for ride $_currentRideId: $truncatedLatitude, $truncatedLongitude',
          tag: 'DriverLocationController',
        );

        _wsService.sendDriverMessage({
          'type': 'tracking_update',
          'ride_id': _currentRideId,
          'latitude': truncatedLatitude,
          'longitude': truncatedLongitude,
        });
      } else if (_isActive) {
        Logger.websocket(
          'Sending Updated Location via WS (stream): $truncatedLatitude, $truncatedLongitude',
          tag: 'DriverLocationController',
        );

        _wsService.sendDriverMessage({
          'type': 'driver_location_update',
          'latitude': truncatedLatitude,
          'longitude': truncatedLongitude,
        });
      }
    } catch (e) {
      Logger.error(
        'Error sending driver location via WebSocket',
        error: e,
        tag: 'DriverLocationController',
      );
    }
  }

  /// Dispose resources
  void dispose() {
    stopLocationUpdates();
  }
}
