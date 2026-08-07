import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../config/app_constants.dart';
import 'logger_service.dart';

/// Centralized location service for handling location permissions and operations
class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  /// Request location permission
  /// Returns true if permission is granted, false otherwise
  Future<bool> requestLocationPermission() async {
    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        Logger.warning(
          'Location services are disabled',
          tag: 'LocationService',
        );
        return false;
      }

      // Check current permission status
      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        // Request permission
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          Logger.warning('Location permission denied', tag: 'LocationService');
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        Logger.warning(
          'Location permissions are permanently denied',
          tag: 'LocationService',
        );
        return false;
      }

      Logger.debug('Location permission granted', tag: 'LocationService');
      return true;
    } catch (e) {
      Logger.error(
        'Error requesting location permission',
        error: e,
        tag: 'LocationService',
      );
      return false;
    }
  }

  /// Get current location
  /// Returns LatLng if successful, null otherwise
  Future<LatLng?> getCurrentLocation({
    LocationAccuracy accuracy = LocationConstants.defaultAccuracy,
  }) async {
    try {
      // Request permission first
      final hasPermission = await requestLocationPermission();
      if (!hasPermission) {
        Logger.warning(
          'Cannot get location: permission not granted',
          tag: 'LocationService',
        );
        return null;
      }

      // Get current position
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: accuracy,
      );

      final location = LatLng(position.latitude, position.longitude);
      Logger.debug(
        'Current location: ${position.latitude}, ${position.longitude}',
        tag: 'LocationService',
      );

      return location;
    } catch (e) {
      Logger.error(
        'Error getting current location',
        error: e,
        tag: 'LocationService',
      );
      return null;
    }
  }

  /// Get location stream for continuous updates
  /// Returns Stream<LatLng> that emits location updates
  Stream<LatLng>? getLocationStream({
    LocationAccuracy accuracy = LocationConstants.defaultAccuracy,
    int distanceFilter = LocationConstants.defaultDistanceFilter,
  }) {
    try {
      final locationSettings = LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
      );

      final positionStream = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      );

      return positionStream.map((position) {
        Logger.debug(
          'Location update: ${position.latitude}, ${position.longitude}',
          tag: 'LocationService',
        );
        return LatLng(position.latitude, position.longitude);
      });
    } catch (e) {
      Logger.error(
        'Error creating location stream',
        error: e,
        tag: 'LocationService',
      );
      return null;
    }
  }

  /// Check if location services are enabled
  Future<bool> isLocationServiceEnabled() async {
    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (e) {
      Logger.error(
        'Error checking location service status',
        error: e,
        tag: 'LocationService',
      );
      return false;
    }
  }

  /// Get distance between two points in meters
  double getDistance(LatLng point1, LatLng point2) {
    const distance = Distance();
    return distance.as(LengthUnit.Meter, point1, point2);
  }

  /// Get bearing between two points in degrees
  double getBearing(LatLng point1, LatLng point2) {
    const distance = Distance();
    return distance.bearing(point1, point2);
  }
}
