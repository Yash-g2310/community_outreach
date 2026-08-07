// Centralized API endpoint constants
// All API endpoints should be defined here for easy maintenance

import 'constants.dart';

/// Authentication endpoints
class AuthEndpoints {
  static String get register => '$kBaseUrl/api/v1/auth/register';
  static String get login => '$kBaseUrl/api/v1/auth/login';
  static String get refresh => '$kBaseUrl/api/v1/auth/refresh';
  static String get me => '$kBaseUrl/api/v1/auth/me';
  static String get profile => '$kBaseUrl/api/v1/auth/profile';
  static String get logout => '$kBaseUrl/api/v1/auth/logout';
}

/// FastAPI ride-service contracts.  New code should use these classes rather
/// than the Django-era endpoint groups below, which are migrated screen by
/// screen to avoid breaking existing UI during the transition.
class RiderEndpoints {
  static String get nearbyDrivers => '$kBaseUrl/api/v1/rider/nearby-drivers';
  static String get requestRide => '$kBaseUrl/api/v1/rider/request';
}

class DriverRideRequestEndpoints {
  static String get pending => '$kBaseUrl/api/v1/driver/ride-requests/pending';
  static String accept(String rideId) =>
      '$kBaseUrl/api/v1/driver/ride-requests/$rideId/accept';
  static String decline(String rideId) =>
      '$kBaseUrl/api/v1/driver/ride-requests/$rideId/decline';
}

class RideEndpoints {
  static String arrive(String rideId) => '$kBaseUrl/api/v1/rides/$rideId/arrive';
  static String start(String rideId) => '$kBaseUrl/api/v1/rides/$rideId/start';
  static String complete(String rideId) => '$kBaseUrl/api/v1/rides/$rideId/complete';
  static String driverCancel(String rideId) =>
      '$kBaseUrl/api/v1/rides/$rideId/driver-cancel';
  static String riderCancel(String rideId) =>
      '$kBaseUrl/api/v1/rides/$rideId/rider-cancel';
  static String snapshot(String rideId) => '$kBaseUrl/api/v1/rides/$rideId/snapshot';
  static String history(String rideId) => '$kBaseUrl/api/v1/rides/$rideId/history';
  static String get listHistory => '$kBaseUrl/api/v1/rides/history';
  static String get active => '$kBaseUrl/api/v1/rides/active';
}

class DriverAvailabilityEndpoints {
  static String get online => '$kBaseUrl/api/v1/driver/online';
  static String get offline => '$kBaseUrl/api/v1/driver/offline';
  static String get status => '$kBaseUrl/api/v1/driver/status';
}
