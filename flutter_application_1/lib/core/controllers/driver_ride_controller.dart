import 'dart:convert';

import '../../config/api_endpoints.dart';
import '../../services/api_service.dart';
import '../../services/logger_service.dart';

/// Driver-facing FastAPI ride-request operations.
class DriverRideController {
  final ApiService _apiService = ApiService();

  /// Declines are persisted by FastAPI, so there is no client-side rejection
  /// cache to restore after reconnecting.
  Future<Set<String>> loadRejectedRides(String _) async => <String>{};

  /// Recover requests that were sent while the driver was briefly offline or
  /// reconnecting.  The backend returns only requests addressed to this driver.
  Future<List<Map<String, dynamic>>> fetchPendingRideRequests() async {
    try {
      final response = await _apiService.get(DriverRideRequestEndpoints.pending);
      if (response.statusCode != 200) {
        Logger.warning(
          'Failed to load pending ride requests: ${response.statusCode}',
          tag: 'DriverRideController',
        );
        return const [];
      }

      final decoded = json.decode(response.body) as Map<String, dynamic>;
      final requests = decoded['requests'] as List<dynamic>? ?? const [];
      return requests
          .whereType<Map>()
          .map((request) => mapRideToNotification(Map<String, dynamic>.from(request)))
          .toList();
    } catch (error) {
      Logger.error(
        'Error loading pending ride requests',
        error: error,
        tag: 'DriverRideController',
      );
      return const [];
    }
  }

  Future<bool> acceptRide(String rideId) async {
    try {
      final response = await _apiService.post(DriverRideRequestEndpoints.accept(rideId));
      if (response.statusCode == 200) {
        Logger.info('Ride $rideId accepted successfully', tag: 'DriverRideController');
        return true;
      }
      Logger.warning(
        'Failed to accept ride: ${response.statusCode}',
        tag: 'DriverRideController',
      );
      return false;
    } catch (error) {
      Logger.error('Error accepting ride', error: error, tag: 'DriverRideController');
      return false;
    }
  }

  Future<bool> declineRide(String rideId) async {
    try {
      final response = await _apiService.post(DriverRideRequestEndpoints.decline(rideId));
      if (response.statusCode == 200) {
        Logger.info('Ride $rideId declined successfully', tag: 'DriverRideController');
        return true;
      }
      Logger.warning(
        'Failed to decline ride: ${response.statusCode}',
        tag: 'DriverRideController',
      );
      return false;
    } catch (error) {
      Logger.error('Error declining ride', error: error, tag: 'DriverRideController');
      return false;
    }
  }

  /// Normalize WebSocket `ride_request` and REST pending-request payloads for
  /// the existing notification widgets.  FastAPI does not reveal rider contact
  /// information before acceptance.
  Map<String, dynamic> mapRideToNotification(Map<String, dynamic> ride) {
    final pickup = ride['pickup'];
    final pickupMap = pickup is Map ? Map<String, dynamic>.from(pickup) : const <String, dynamic>{};
    return {
      'id': (ride['ride_id'] ?? ride['id'])?.toString(),
      'start': ride['pickup_address']?.toString() ?? 'Pickup location',
      'end': ride['dropoff_address']?.toString() ?? 'Destination not provided',
      'people': ride['passenger_count'] ?? ride['number_of_passengers'] ?? 1,
      'pickup_lat': pickupMap['latitude'] ?? pickupMap['lat'],
      'pickup_lng': pickupMap['longitude'] ?? pickupMap['lng'],
    };
  }
}
