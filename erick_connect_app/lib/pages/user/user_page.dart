import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'dart:async';
import 'dart:convert';
import '../profile/profile_page.dart';
import '../../utils/string_utils.dart';
import 'previous_rides.dart';
import 'user_tracking_page.dart';
import 'ride_loading_page.dart';
import '../../services/auth_service.dart';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';
import '../../services/location_service.dart';
import '../../services/api_service.dart';
import '../../config/api_endpoints.dart';
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
  bool _isLoadingDrivers = false;
  final List<Map<String, dynamic>> _nearbyDrivers = [];
  Timer? _nearbyDriversRefreshTimer;

  // Services and controllers
  final AuthService _authService = AuthService();
  final ErrorService _errorService = ErrorService();
  final UserWebSocketController _wsController = UserWebSocketController();
  final UserRideController _rideController = UserRideController();
  final ApiService _apiService = ApiService();

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
    _nearbyDriversRefreshTimer?.cancel();
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
        await _connectPassengerSocket();
        if (await _restoreActiveRide()) return;
        _refreshNearbyDrivers();
        _nearbyDriversRefreshTimer = Timer.periodic(
          const Duration(seconds: 10),
          (_) => _refreshNearbyDrivers(),
        );
      }
    } catch (e) {
      Logger.error('Error getting location', error: e, tag: 'UserPage');
    }
  }

  /// Resume an in-progress request/ride after the app was fully restarted.
  /// The server remains the source of truth; no ride state is persisted locally.
  Future<bool> _restoreActiveRide() async {
    try {
      final response = await _apiService.get(RideEndpoints.active);
      if (response.statusCode != 200 || response.body == 'null') return false;
      final data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      final rideId = data['id']?.toString();
      final status = data['status']?.toString();
      if (rideId == null || rideId.isEmpty || status == null || !mounted)
        return false;

      if (status == 'searching') {
        AppRouter.pushReplacement(context, RideLoadingPage(rideId: rideId));
      } else {
        AppRouter.pushReplacement(context, UserTrackingPage(rideId: rideId));
      }
      return true;
    } catch (error) {
      Logger.warning(
        'Unable to recover an active rider ride: $error',
        tag: 'UserPage',
      );
      return false;
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
      onMessage: _handlePassengerSocketMessage,
      onReconnect: _resyncAfterSocketReconnect,
    );
  }

  Future<void> _resyncAfterSocketReconnect() async {
    if (!mounted) return;
    if (await _restoreActiveRide()) return;
    await _refreshNearbyDrivers();
  }

  /// Nearby-driver positions come from FastAPI's Redis-backed REST endpoint.
  Future<void> _refreshNearbyDrivers() async {
    final position = _currentPosition;
    if (position == null) return;

    safeSetState(() => _isLoadingDrivers = true);
    final drivers = await _rideController.fetchNearbyDrivers(position);
    if (!mounted) return;
    safeSetState(() {
      _nearbyDrivers
        ..clear()
        ..addAll(drivers);
      _isLoadingDrivers = false;
    });
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
          final rideId = data['ride_id']?.toString();
          if (rideId != null && rideId.isNotEmpty) {
            AppRouter.pushReplacement(
              context,
              UserTrackingPage(rideId: rideId),
            );
          }
          break;

        case 'ride_request_expired':
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
        final driverCandidates =
            (responseData['driver_candidates'] as num?)?.toInt() ?? 0;
        if (driverCandidates == 0) {
          _errorService.showError(
            context,
            responseData['message']?.toString() ??
                'No drivers are available nearby. Please try again later.',
          );
          return;
        }

        _errorService.showSuccess(
          context,
          'Ride request created! ID: ${responseData['id']}',
        );

        // Clear form
        _pickupController.clear();
        _dropController.clear();
        _passengerController.clear();

        if (mounted) {
          AppRouter.push(
            context,
            RideLoadingPage(rideId: responseData['id']?.toString()),
          );
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
  void _showLogoutDialog(BuildContext pageContext) {
    showDialog(
      context: pageContext,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Logout'),
          content: const Text('Are you sure you want to logout?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(); // Close dialog
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Logger.info('User Logged out', tag: 'UserPage');

                Navigator.of(dialogContext).pop(); // Close dialog

                await AuthService().clearAuthData();
                if (!mounted) return;

                Navigator.of(this.context).pushNamedAndRemoveUntil(
                  AppRouter.login,
                  (Route<dynamic> route) => false,
                );
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
