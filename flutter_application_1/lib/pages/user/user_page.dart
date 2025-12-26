import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'dart:async';
import '../profile/profile_page.dart';
import '../../utils/string_utils.dart';
import 'previous_rides.dart';
import 'user_tracking_page.dart';
import 'ride_loading_page.dart';
import '../../services/auth_service.dart';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';
import '../../services/location_service.dart';
import '../../router/app_router.dart';
import '../../core/mixins/safe_state_mixin.dart';
import '../../core/controllers/user_websocket_controller.dart';
import '../../core/controllers/user_ride_controller.dart';
import '../../core/widgets/user_map_widget.dart';
import '../../core/widgets/nearby_drivers_info.dart';
import '../../core/widgets/ride_request_form.dart';

class UserMapScreen extends StatefulWidget {
  const UserMapScreen({super.key});

  @override
  State<UserMapScreen> createState() => _UserMapScreenState();
}

class _UserMapScreenState extends State<UserMapScreen> with SafeStateMixin {
  LatLng? _currentPosition;
  bool _isLoading = false;
  final _isLoadingDrivers = false;
  final List<Map<String, dynamic>> _nearbyDrivers = [];

  // Services and controllers
  final AuthService _authService = AuthService();
  final ErrorService _errorService = ErrorService();
  final UserWebSocketController _wsController = UserWebSocketController();
  final UserRideController _rideController = UserRideController();

  // Controllers for text input fields
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropController = TextEditingController();
  final TextEditingController _passengerController = TextEditingController();

  // API Configuration uses centralized base URL from constants

  @override
  void initState() {
    super.initState();
    _loadCurrentLocation();
  }

  @override
  void dispose() {
    // Dispose WebSocket controller
    _wsController.dispose();

    // Dispose text controllers
    _pickupController.dispose();
    _dropController.dispose();
    _passengerController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentLocation() async {
    try {
      final locationService = LocationService();
      final location = await locationService.getCurrentLocation();

      if (location == null) {
        throw Exception('Unable to get current location.');
      }

      safeSetState(() {
        _currentPosition = location;
      });

      Logger.debug(
        'Current location: ${location.latitude}, ${location.longitude}',
        tag: 'UserPage',
      );

      // Check if authenticated before connecting WebSocket
      final authState = await _authService.getAuthState();
      if (authState.isAuthenticated) {
        _connectPassengerSocket();
      }
    } catch (e) {
      Logger.error('Error getting location', error: e, tag: 'UserPage');
    }
  }

  // ============================================================
  // 🔌 Connect to passenger WebSocket for ride status updates
  // ============================================================
  Future<void> _connectPassengerSocket() async {
    final authState = await _authService.getAuthState();
    if (!authState.isAuthenticated) return;

    await _wsController.connect(
      jwtToken: authState.accessToken,
      sessionId: null, // Not needed - WebSocket handles auth via token
      csrfToken: null, // Not needed - WebSocket handles auth via token
      currentPosition: _currentPosition,
      onMessage: _handlePassengerSocketMessage,
    );
  }

  // ============================================================
  // 📨 Handle incoming WebSocket messages
  // ============================================================
  Future<void> _handlePassengerSocketMessage(Map<String, dynamic> data) async {
    try {
      if (!_wsController.shouldProcessEvent(data)) return;

      final eventType = data['type'] as String?;
      if (eventType == null) return;

      Logger.websocket(
        'Passenger WS event on user_page: $eventType',
        tag: 'UserPage',
      );

      switch (eventType) {
        case 'ride_accepted':
          // Driver accepted the ride. Navigate to tracking page.
          // WebSocket service persists, so no transfer needed.
          Logger.info(
            'Driver accepted ride (user_page) — opening tracking page',
            tag: 'UserPage',
          );

          // If a loading screen is on top, pop it first so replacement
          // correctly shows the tracking page.
          if (AppRouter.canPop(context)) {
            AppRouter.pop(context);
          }

          // Navigate to tracking page - WebSocket service will handle messages
          AppRouter.pushReplacement(context, const UserTrackingPage());
          break;

        case 'ride_cancelled':
          // If a loading screen (RideLoadingPage) is on top, close it
          if (AppRouter.canPop(context)) {
            try {
              AppRouter.pop(context);
            } catch (e) {
              Logger.warning(
                'Warning popping loading screen on ride_cancelled: $e',
                tag: 'UserPage',
              );
            }
          }
          final String cancelMsg = data['message'] ?? 'Ride was cancelled.';
          _showErrorDialog('Ride Cancelled', cancelMsg);
          break;

        case 'ride_expired':
          if (AppRouter.canPop(context)) {
            try {
              AppRouter.pop(context);
            } catch (e) {
              Logger.warning(
                'Warning popping loading screen on ride_expired: $e',
                tag: 'UserPage',
              );
            }
          }
          final String expiredMsg =
              data['message'] ??
              'No driver accepted the request. Try again later.';
          _showErrorDialog('Ride Expired', expiredMsg);
          break;

        case 'no_drivers_available':
          if (AppRouter.canPop(context)) {
            try {
              AppRouter.pop(context);
            } catch (e) {
              Logger.warning(
                'Warning popping loading screen on no_drivers_available: $e',
                tag: 'UserPage',
              );
            }
          }
          final String ndMsg =
              data['message'] ??
              'No drivers available nearby. Try again later.';
          _showErrorDialog('No Drivers Nearby', ndMsg);
          break;

        // ============================================================
        // NEARBY DRIVER EVENTS
        // ============================================================

        case 'driver_status_changed':
          _handleDriverStatusChanged(data);
          break;

        case 'driver_location_updated':
          _handleDriverLocationUpdated(data);
          break;

        default:
          Logger.warning(
            'Unhandled passenger WS event: $eventType',
            tag: 'UserPage',
          );
      }
    } catch (e) {
      Logger.error(
        'Error parsing passenger WebSocket message',
        error: e,
        tag: 'UserPage',
      );
    }
  }

  // ============================================================
  // Handle driver going online/offline
  // ============================================================
  void _handleDriverStatusChanged(Map<String, dynamic> data) {
    final driverId = int.tryParse("${data['driver_id']}");
    final status = data['status'];

    if (driverId == null || !mounted) return;

    Logger.debug("Driver $driverId status changed → $status", tag: 'UserPage');

    // Only action needed: remove driver if explicitly offline
    if (status == "offline" || status == "busy") {
      safeSetState(() {
        _nearbyDrivers.removeWhere((d) => d['driver_id'] == driverId);
      });
    }
  }

  // ============================================================
  // Handle driver location update
  // ============================================================
  void _handleDriverLocationUpdated(Map<String, dynamic> data) {
    if (!mounted) return;

    final driverId = int.tryParse("${data['driver_id']}");
    final double? latitude = (data['latitude'] as num?)?.toDouble();
    final double? longitude = (data['longitude'] as num?)?.toDouble();

    if (driverId == null || latitude == null || longitude == null) {
      Logger.warning("Ignoring invalid location update.", tag: 'UserPage');
      return;
    }

    final String username = data['username']?.toString() ?? "Driver $driverId";
    final String vehicleNumber =
        data['vehicle_number']?.toString() ??
        data['vehicle_no']?.toString() ??
        "N/A";

    safeSetState(() {
      final index = _nearbyDrivers.indexWhere(
        (d) => d['driver_id'] == driverId,
      );

      if (index == -1) {
        // Add new driver
        _nearbyDrivers.add({
          'driver_id': driverId,
          'username': username,
          'vehicle_number': vehicleNumber,
          'latitude': latitude,
          'longitude': longitude,
        });
      } else {
        // Update existing
        _nearbyDrivers[index]['latitude'] = latitude;
        _nearbyDrivers[index]['longitude'] = longitude;
        _nearbyDrivers[index]['username'] = username;
        _nearbyDrivers[index]['vehicle_number'] = vehicleNumber;
      }
    });
  }

  // ============================================================
  // Create ride request API call
  Future<void> _createRideRequest() async {
    // Validation
    if (_pickupController.text.trim().isEmpty) {
      _errorService.showError(context, 'Please enter pickup location');
      return;
    }

    if (_dropController.text.trim().isEmpty) {
      _errorService.showError(context, 'Please enter drop location');
      return;
    }

    if (_passengerController.text.trim().isEmpty) {
      _errorService.showError(context, 'Please enter number of passengers');
      return;
    }

    final int passengers = int.tryParse(_passengerController.text.trim()) ?? 0;
    if (passengers <= 0) {
      _errorService.showError(
        context,
        'Please enter valid number of passengers',
      );
      return;
    }

    if (_currentPosition == null) {
      _errorService.showError(
        context,
        'Location not available. Please wait and try again.',
      );
      return;
    }

    safeSetState(() => _isLoading = true);

    try {
      final responseData = await _rideController.createRideRequest(
        currentPosition: _currentPosition!,
        pickupAddress: _pickupController.text.trim(),
        dropoffAddress: _dropController.text.trim(),
        numberOfPassengers: passengers,
      );

      if (responseData != null && mounted) {
        _errorService.showSuccess(
          context,
          'Ride request created! ID: ${responseData['id']}',
        );

        // Clear form
        _pickupController.clear();
        _dropController.clear();
        _passengerController.clear();

        if (mounted) {
          AppRouter.push(context, RideLoadingPage(rideId: responseData['id']));
        }
      } else {
        _errorService.showError(context, 'Failed to create ride request');
      }
    } catch (e) {
      _errorService.handleError(context, e);
    } finally {
      safeSetState(() => _isLoading = false);
    }
  }

  // Handle profile navigation
  Future<void> _handleProfileNavigation() async {
    final userData = await _authService.getUserData();
    final token = await _authService.getAccessToken();
    if (!mounted) return;
    AppRouter.push(
      context,
      ProfilePage(
        userType: userData?['role']?.toString().capitalize() ?? 'User',
        userName: userData?['username'] ?? 'E-Rick User',
        userEmail: userData?['email'] ?? 'user@erick.com',
        accessToken: token,
      ),
    );
  }

  // Handle rides navigation
  Future<void> _handleRidesNavigation() async {
    final authState = await _authService.getAuthState();
    if (!authState.isAuthenticated) {
      if (!mounted) return;
      _errorService.showError(context, 'Please login to view previous rides.');
      return;
    }
    if (!mounted) return;
    AppRouter.push(context, const PreviousRidesPage(isDriver: false));
  }

  // Show an AlertDialog for important passenger events (cancel/expired/no drivers)
  void _showErrorDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  // Show logout confirmation dialog
  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Logout'),
          content: const Text('Are you sure you want to logout?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Logger.info('User Logged out', tag: 'UserPage');

                Navigator.of(context).pop(); // Close dialog

                // Navigate back to login page and clear all previous routes
                // Clear auth data and navigate to splash
                await AuthService().clearAuthData();
                if (context.mounted) {
                  Navigator.of(context).pushNamedAndRemoveUntil(
                    AppRouter.splash,
                    (Route<dynamic> route) => false,
                  );
                }
              },
              child: const Text('Logout', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Passenger Page'),
        leading: IconButton(
          onPressed: () {
            _showLogoutDialog(context);
          },
          icon: const Icon(Icons.logout, color: Colors.red),
          tooltip: 'Logout',
        ),
        actions: [
          // Profile menu: Profile | Previous Rides
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.account_circle,
              size: 28,
              color: Colors.blueGrey,
            ),
            onSelected: (value) {
              if (value == 'profile') {
                _handleProfileNavigation();
              } else if (value == 'rides') {
                _handleRidesNavigation();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'profile', child: Text('Profile')),
              const PopupMenuItem(
                value: 'rides',
                child: Text('Previous Rides'),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),

      body: _currentPosition == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Map (top half)
                UserMapWidget(
                  currentPosition: _currentPosition!,
                  nearbyDrivers: _nearbyDrivers,
                ),

                // Bottom part (inputs + button)
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        // Nearby drivers info
                        NearbyDriversInfo(
                          nearbyDrivers: _nearbyDrivers,
                          isLoading: _isLoadingDrivers,
                        ),
                        if (_nearbyDrivers.isNotEmpty)
                          const SizedBox(height: 10),

                        // Ride request form
                        RideRequestForm(
                          pickupController: _pickupController,
                          dropController: _dropController,
                          passengerController: _passengerController,
                          onSubmit: _createRideRequest,
                          isLoading: _isLoading,
                          enabled: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
