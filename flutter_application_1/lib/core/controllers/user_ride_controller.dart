import 'dart:convert';
import 'package:latlong2/latlong.dart';
import '../../services/api_service.dart';
import '../../services/logger_service.dart';
import '../../config/api_endpoints.dart';

/// Controller for managing user ride requests
class UserRideController {
  final ApiService _apiService = ApiService();

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
        PassengerEndpoints.request,
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
