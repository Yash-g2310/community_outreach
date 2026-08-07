import 'dart:convert';
import 'package:latlong2/latlong.dart';
import '../../services/api_service.dart';
import '../../services/logger_service.dart';
import '../../config/api_endpoints.dart';

/// Controller for managing user ride requests
class UserRideController {
  final ApiService _apiService = ApiService();

  /// Read nearby available driver pins from the FastAPI Redis-backed endpoint.
  /// Driver identities and vehicle details are intentionally not returned until
  /// a ride is accepted.
  Future<List<Map<String, dynamic>>> fetchNearbyDrivers(
    LatLng currentPosition,
  ) async {
    final latitude = _truncateCoordinate(currentPosition.latitude);
    final longitude = _truncateCoordinate(currentPosition.longitude);
    final endpoint =
        '${RiderEndpoints.nearbyDrivers}?latitude=$latitude&longitude=$longitude&radius_meters=1500';

    try {
      final response = await _apiService.get(endpoint);
      if (response.statusCode != 200) {
        Logger.warning(
          'Failed to load nearby drivers: ${response.statusCode}',
          tag: 'UserRideController',
        );
        return const [];
      }

      final decoded = json.decode(response.body) as Map<String, dynamic>;
      final drivers = decoded['drivers'] as List<dynamic>? ?? const [];
      return drivers
          .whereType<Map>()
          .map((driver) => Map<String, dynamic>.from(driver))
          .toList();
    } catch (error) {
      Logger.error(
        'Error loading nearby drivers',
        error: error,
        tag: 'UserRideController',
      );
      return const [];
    }
  }

  /// Create a ride request
  Future<Map<String, dynamic>?> createRideRequest({
    required LatLng currentPosition,
    required String pickupAddress,
    required String dropoffAddress,
    required int numberOfPassengers,
  }) async {
    try {
      final rideData = {
        'pickup_latitude': _truncateCoordinate(currentPosition.latitude),
        'pickup_longitude': _truncateCoordinate(currentPosition.longitude),
        'pickup_address': pickupAddress,
        'dropoff_address': dropoffAddress,
        'number_of_passengers': numberOfPassengers,
      };

      Logger.info(
        'Creating ride request: $rideData',
        tag: 'UserRideController',
      );

      final response = await _apiService.post(
        RiderEndpoints.requestRide,
        body: rideData,
      );

      Logger.network(
        'Response status: ${response.statusCode}',
        tag: 'UserRideController',
      );
      Logger.debug(
        'Response body: ${response.body}',
        tag: 'UserRideController',
      );

      if (response.statusCode == 201) {
        final responseData = json.decode(response.body);
        Logger.info(
          'Ride request created successfully: ${responseData['id']}',
          tag: 'UserRideController',
        );
        return responseData;
      } else {
        Logger.warning(
          'Failed to create ride request: ${response.statusCode}',
          tag: 'UserRideController',
        );
        return null;
      }
    } catch (e) {
      Logger.error(
        'Error creating ride request',
        error: e,
        tag: 'UserRideController',
      );
      return null;
    }
  }

  /// Truncate coordinate to 6 decimal places
  double _truncateCoordinate(double coordinate) {
    return double.parse(coordinate.toStringAsFixed(6));
  }
}
