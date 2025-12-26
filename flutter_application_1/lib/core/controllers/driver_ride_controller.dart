import 'package:shared_preferences/shared_preferences.dart';
import '../../services/api_service.dart';
import '../../services/logger_service.dart';
import '../../config/api_endpoints.dart';

/// Controller for managing driver ride operations (accept, reject, notifications)
class DriverRideController {
  final ApiService _apiService = ApiService();
  Set<int> _rejectedRideIds = {};

  /// Load rejected ride IDs from local storage
  Future<Set<int>> loadRejectedRides(String driverId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rejectedList =
          prefs.getStringList('rejected_rides_$driverId') ?? [];

      _rejectedRideIds = rejectedList
          .map((id) => int.tryParse(id))
          .where((id) => id != null)
          .cast<int>()
          .toSet();

      Logger.debug(
        'Loaded ${_rejectedRideIds.length} rejected rides from local storage',
        tag: 'DriverRideController',
      );
      return _rejectedRideIds;
    } catch (e) {
      Logger.error(
        'Error loading rejected rides',
        error: e,
        tag: 'DriverRideController',
      );
      _rejectedRideIds = {};
      return _rejectedRideIds;
    }
  }

  /// Check if ride was previously rejected
  bool isRejected(int rideId) {
    return _rejectedRideIds.contains(rideId);
  }

  /// Accept a ride
  Future<bool> acceptRide(int rideId) async {
    try {
      final response = await _apiService.post(
        RideHandlingEndpoints.accept(rideId),
      );

      if (response.statusCode == 200) {
        Logger.info(
          'Ride $rideId accepted successfully',
          tag: 'DriverRideController',
        );
        return true;
      } else {
        Logger.warning(
          'Failed to accept ride: ${response.statusCode}',
          tag: 'DriverRideController',
        );
        return false;
      }
    } catch (e) {
      Logger.error(
        'Error accepting ride',
        error: e,
        tag: 'DriverRideController',
      );
      return false;
    }
  }

  /// Reject a ride
  Future<bool> rejectRide(int rideId, String driverId) async {
    try {
      final response = await _apiService.post(
        RideHandlingEndpoints.reject(rideId),
      );

      if (response.statusCode == 200) {
        // Add to rejected list and save
        _rejectedRideIds.add(rideId);
        await _saveRejectedRides(driverId);

        Logger.info(
          'Ride $rideId rejected and saved to local storage',
          tag: 'DriverRideController',
        );
        return true;
      } else {
        Logger.warning(
          'Failed to reject ride: ${response.statusCode}',
          tag: 'DriverRideController',
        );
        return false;
      }
    } catch (e) {
      Logger.error(
        'Error rejecting ride',
        error: e,
        tag: 'DriverRideController',
      );
      return false;
    }
  }

  /// Save rejected ride IDs to local storage
  Future<void> _saveRejectedRides(String driverId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rejectedList = _rejectedRideIds.map((id) => id.toString()).toList();
      await prefs.setStringList('rejected_rides_$driverId', rejectedList);
      Logger.debug(
        'Saved ${_rejectedRideIds.length} rejected rides to local storage',
        tag: 'DriverRideController',
      );
    } catch (e) {
      Logger.error(
        'Error saving rejected rides',
        error: e,
        tag: 'DriverRideController',
      );
    }
  }

  /// Map raw ride payload to notification format
  Map<String, dynamic> mapRideToNotification(Map<String, dynamic> ride) {
    final passengerData = ride['passenger'];
    String passengerName = 'Unknown';
    String passengerPhone = '';

    if (passengerData is Map) {
      passengerName = passengerData['username']?.toString() ?? 'Unknown';
      passengerPhone = passengerData['phone_number']?.toString() ?? '';
    } else {
      passengerName = ride['passenger_name']?.toString() ?? 'Unknown';
      passengerPhone = ride['passenger_phone']?.toString() ?? '';
    }

    return {
      'id': ride['id'],
      'start': ride['pickup_address'] ?? 'Unknown pickup',
      'end': ride['dropoff_address'] ?? 'Unknown destination',
      'people': ride['number_of_passengers'] ?? ride['passengers'] ?? 1,
      'distance': ride['distance_from_driver'] ?? ride['distance'] ?? 0,
      'passenger_name': passengerName,
      'passenger_phone': passengerPhone,
      'pickup_lat': ride['pickup_latitude'] ?? ride['pickup_lat'],
      'pickup_lng': ride['pickup_longitude'] ?? ride['pickup_lng'],
      'dropoff_lat': ride['dropoff_latitude'] ?? ride['dropoff_lat'],
      'dropoff_lng': ride['dropoff_longitude'] ?? ride['dropoff_lng'],
      'requested_at': ride['requested_at'],
    };
  }
}
