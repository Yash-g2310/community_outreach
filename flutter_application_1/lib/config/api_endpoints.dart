// Centralized API endpoint constants
// All API endpoints should be defined here for easy maintenance

import 'constants.dart';

/// Authentication endpoints
class AuthEndpoints {
  static String get register => '$kBaseUrl/api/auth/register/';
  static String get login => '$kBaseUrl/api/auth/login/';
  static String get refresh => '$kBaseUrl/api/auth/refresh/';
}

/// User profile endpoints
class UserProfileEndpoints {
  static String get profile => '$kBaseUrl/api/rides/user/profile/';
}

/// Driver profile and status endpoints
class DriverEndpoints {
  static String get profile => '$kBaseUrl/api/rides/driver/profile/';
  static String get status => '$kBaseUrl/api/rides/driver/status/';
  static String get location => '$kBaseUrl/api/rides/driver/location/';
  static String get nearbyRides => '$kBaseUrl/api/rides/driver/nearby-rides/';
  static String get currentRide => '$kBaseUrl/api/rides/driver/current-ride/';
  static String get history => '$kBaseUrl/api/rides/driver/history/';
}

/// Passenger/ride request endpoints
class PassengerEndpoints {
  static String get nearbyDrivers =>
      '$kBaseUrl/api/rides/passenger/nearby-drivers/';
  static String get request => '$kBaseUrl/api/rides/passenger/request/';
  static String get current => '$kBaseUrl/api/rides/passenger/current/';
  static String get history => '$kBaseUrl/api/rides/passenger/history/';
  static String cancel(int rideId) =>
      '$kBaseUrl/api/rides/passenger/$rideId/cancel/';
}

/// Ride handling endpoints (accept, reject, complete, cancel)
class RideHandlingEndpoints {
  static String accept(int rideId) =>
      '$kBaseUrl/api/rides/handle/$rideId/accept/';
  static String reject(int rideId) =>
      '$kBaseUrl/api/rides/handle/$rideId/reject/';
  static String complete(int rideId) =>
      '$kBaseUrl/api/rides/handle/$rideId/complete/';
  static String driverCancel(int rideId) =>
      '$kBaseUrl/api/rides/handle/$rideId/driver-cancel/';
}
