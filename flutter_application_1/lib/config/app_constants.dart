// Application-wide constants
// Centralized location for all magic numbers and configuration values

import 'package:geolocator/geolocator.dart';

/// Network-related constants
class NetworkConstants {
  /// Default timeout for HTTP requests
  static const Duration requestTimeout = Duration(seconds: 30);

  /// Timeout for environment configuration loading
  static const Duration envConfigTimeout = Duration(milliseconds: 500);

  /// Maximum number of retry attempts for network requests
  static const int maxRetryAttempts = 3;

  /// Delay between retry attempts
  static const Duration retryDelay = Duration(seconds: 2);
}

/// Location-related constants
class LocationConstants {
  /// Default location accuracy for position requests
  static const LocationAccuracy defaultAccuracy = LocationAccuracy.high;

  /// Default distance filter for position streams (in meters)
  /// Only emit location updates when device moves this distance
  static const int defaultDistanceFilter = 50;

  /// High accuracy setting for critical location operations
  static const LocationAccuracy highAccuracy = LocationAccuracy.high;

  /// Medium accuracy setting for less critical operations
  static const LocationAccuracy mediumAccuracy = LocationAccuracy.medium;
}

/// WebSocket-related constants
class WebSocketConstants {
  /// Maximum number of reconnection attempts
  static const int maxReconnectAttempts = 5;

  /// Base delay before first reconnection attempt
  static const Duration baseReconnectDelay = Duration(seconds: 2);

  /// Maximum delay between reconnection attempts (exponential backoff cap)
  static const Duration maxReconnectDelay = Duration(seconds: 60);
}

/// UI-related constants
class UIConstants {
  /// Default animation duration
  static const Duration defaultAnimationDuration = Duration(seconds: 2);

  /// Short delay for UI transitions
  static const Duration shortDelay = Duration(seconds: 2);

  /// SnackBar default display duration
  static const Duration snackBarDuration = Duration(seconds: 4);

  /// Success message display duration
  static const Duration successMessageDuration = Duration(seconds: 3);

  /// Error message display duration
  static const Duration errorMessageDuration = Duration(seconds: 4);
}

/// Timer-related constants
class TimerConstants {
  /// Location update interval for driver tracking
  static const Duration locationUpdateInterval = Duration(seconds: 10);

  /// Periodic timer interval for location updates
  static const Duration periodicUpdateInterval = Duration(seconds: 10);
}
