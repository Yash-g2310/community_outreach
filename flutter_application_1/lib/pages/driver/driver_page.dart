import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'package:latlong2/latlong.dart';
import '../profile/profile_page.dart';
import 'driver_tracking_page.dart';
import '../user/previous_rides.dart';
import '../../config/api_endpoints.dart';
import '../../services/auth_service.dart';
import '../../services/api_service.dart';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';
import '../../services/location_service.dart';
import '../../router/app_router.dart';
import '../../core/mixins/safe_state_mixin.dart';
import '../../core/controllers/driver_location_controller.dart';
import '../../core/controllers/driver_websocket_controller.dart';
import '../../core/widgets/driver_map_widget.dart';
import '../../core/widgets/driver_status_controls.dart';
import '../../core/widgets/ride_notification_list.dart';
import '../../core/widgets/ride_request_bottom_sheet.dart';

class DriverPage extends StatefulWidget {
  const DriverPage({super.key});

  @override
  State<DriverPage> createState() => _DriverPageState();
}

class _DriverPageState extends State<DriverPage> with SafeStateMixin {
  bool isActive = true;
  bool isLoading = false;
  String? errorMessage;
  Map<String, dynamic>? driverProfile;
  LatLng? _mapPosition; // For displaying on map
  int? _currentRideId;

  // API Configuration uses centralized base URL from constants

  List<Map<String, dynamic>> notifications = [];
  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();
  final LocationService _locationService = LocationService();
  final DriverLocationController _locationController =
      DriverLocationController();
  final DriverWebSocketController _wsController = DriverWebSocketController();
  final ErrorService _errorService = ErrorService();

  @override
  void initState() {
    super.initState();
    _loadDriverData();
    _loadCurrentLocation();
  }

  @override
  void dispose() {
    // Dispose controllers
    _wsController.dispose();
    _locationController.dispose();

    // Ensure server marks driver offline when the app/widget is disposed
    _sendDriverOfflineSilently();

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
        _mapPosition = location;
      });

      Logger.debug(
        'Initial Location: ${location.latitude}, ${location.longitude}',
        tag: 'DriverPage',
      );
      // Location updates will be started after loading driver profile
    } catch (e) {
      Logger.error('Error initializing location', error: e, tag: 'DriverPage');
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      final location = await _locationService.getCurrentLocation();

      if (location == null) {
        throw Exception('Unable to get current location.');
      }

      // Update map position
      safeSetState(() {
        _mapPosition = location;
      });

      Logger.debug(
        'Current location: ${location.latitude}, ${location.longitude}',
        tag: 'DriverPage',
      );

      // WebSocket connection is now handled in _loadDriverData()
      // to ensure it connects before location updates start
    } catch (e) {
      Logger.error(
        'Error getting current location',
        error: e,
        tag: 'DriverPage',
      );
    }
  }

  void _startLocationUpdates() {
    _locationController.setActive(isActive);
    _locationController.setCurrentRideId(_currentRideId);
    _locationController.startLocationUpdates(
      isActive: isActive,
      onLocationUpdate: (LatLng location) {
        safeSetState(() {
          _mapPosition = location;
        });
      },
    );
  }

  void _stopLocationUpdates() {
    _locationController.stopLocationUpdates();
  }

  Future<void> _connectDriverSocket() async {
    final authState = await _authService.getAuthState();
    if (!authState.isAuthenticated) return;
    
    await _wsController.connect(
      jwtToken: authState.accessToken,
      sessionId: null, // Not needed - WebSocket handles auth via token
      csrfToken: null, // Not needed - WebSocket handles auth via token
      onMessage: (data) {
        if (!mounted) return;
        _wsController.processMessage(
          data,
          onRideOffer: _handleIncomingRide,
          onRideRemoval: _handleRideRemoval,
          onCurrentRideCleared: (rideId) {
            _currentRideId = null;
            _locationController.setCurrentRideId(null);
          },
          isActive: isActive,
          stopLocationUpdates: _stopLocationUpdates,
          startLocationUpdates: _startLocationUpdates,
        );
      },
    );
  }

  void _handleIncomingRide(Map<String, dynamic> ridePayload) async {
    final rideId = ridePayload['id'];
    if (rideId == null) return;

    // Check if previously rejected
    final userData = await _authService.getUserData();
    final driverId = userData?['id']?.toString() ?? 'unknown';
    _wsController.rideController.loadRejectedRides(driverId).then((rejected) {
      if (rejected.contains(rideId)) {
        Logger.debug(
          'Ignoring ride $rideId - previously rejected',
          tag: 'DriverPage',
        );
        return;
      }

      final mappedRide = _wsController.rideController.mapRideToNotification(
        ridePayload,
      );
      safeSetState(() {
        final updated = List<Map<String, dynamic>>.from(notifications);
        final existingIndex = updated.indexWhere(
          (notif) => notif['id'] == rideId,
        );
        if (existingIndex >= 0) {
          updated[existingIndex] = mappedRide;
        } else {
          updated.insert(0, mappedRide);
        }
        notifications = updated;
      });

      _errorService.showSuccess(context, 'New ride request received! 🚗');
    });
  }

  void _handleRideRemoval(dynamic rideIdRaw, String reason) {
    final rideId = rideIdRaw is int ? rideIdRaw : int.tryParse('$rideIdRaw');
    if (rideId == null) return;

    var removed = false;
    safeSetState(() {
      final updated = notifications
          .where((notif) => notif['id'] != rideId)
          .toList();
      removed = updated.length != notifications.length;
      notifications = updated;
    });

    if (removed) {
      _errorService.showSuccess(context, reason);
    }
  }

  Future<void> _loadDriverData() async {
    final token = await _authService.getAccessToken();
    if (token == null || token.isEmpty) {
      safeSetState(() {
        errorMessage = 'No authentication token found';
      });
      return;
    }

    safeSetState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      // Load driver profile first, then nearby rides (need profile for fallback location)
      await _fetchDriverProfile();

      // Connect WebSocket first before starting location updates
      await _connectDriverSocket();

      // Start location updates if driver is active (after WebSocket is connected)
      if (isActive) {
        _startLocationUpdates();
      }
    } catch (e) {
      safeSetState(() {
        errorMessage = 'Error loading driver data: $e';
      });
    } finally {
      safeSetState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _fetchDriverProfile() async {
    try {
      final response = await _apiService.get(DriverEndpoints.profile);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        safeSetState(() {
          driverProfile = data;
          // Update isActive based on driver status
          isActive = data['status'] == 'available';
        });
      } else {
        throw Exception(
          'Failed to load driver profile: ${response.statusCode}',
        );
      }
    } catch (e) {
      Logger.error('Driver profile error', error: e, tag: 'DriverPage');
      rethrow;
    }
  }

  Future<void> _updateDriverStatus(bool active) async {
    final token = await _authService.getAccessToken();
    if (token == null || token.isEmpty) return;

    safeSetState(() {
      isLoading = true;
    });

    try {
      // Get current GPS location before updating status
      final currentPos = _locationController.currentPosition;
      if (currentPos == null) {
        await _getCurrentLocation();
      }

      // Use current GPS location or fallback to null
      final location = _locationController.currentPosition ?? _mapPosition;
      double? latitude = location?.latitude;
      double? longitude = location?.longitude;

      final response = await _apiService.patch(
        DriverEndpoints.status,
        body: {
          'status': active ? 'available' : 'offline',
          if (latitude != null && longitude != null) ...{
            'current_latitude': double.parse(latitude.toStringAsFixed(6)),
            'current_longitude': double.parse(longitude.toStringAsFixed(6)),
          },
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        safeSetState(() {
          isActive = active;
        });

        // Start or stop location updates based on status
        if (active) {
          _startLocationUpdates();
          // No need to fetch nearby rides when going online; ride requests come via WebSocket.
        } else {
          _stopLocationUpdates();
          // Clear notifications when going offline
          safeSetState(() {
            notifications = [];
          });
        }

        _errorService.showSuccess(
          context,
          active ? 'You are now available for rides' : 'You are now offline',
        );
      } else {
        _errorService.handleError(context, null, response: response);
      }
    } catch (e) {
      _errorService.handleError(context, e);
    } finally {
      safeSetState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _acceptRide(Map<String, dynamic> notification) async {
    final token = await _authService.getAccessToken();
    if (token == null || token.isEmpty) return;

    final rideId = notification['id'] as int;
    safeSetState(() => isLoading = true);

    try {
      final success = await _wsController.rideController.acceptRide(rideId);
      if (!mounted) return;

      if (success) {
        safeSetState(() {
          notifications.removeWhere((notif) => notif['id'] == rideId);
        });

        _errorService.showSuccess(context, 'Ride accepted successfully! ✅');

        _currentRideId = rideId;
        _locationController.setCurrentRideId(rideId);

        if (mounted) {
          AppRouter.pushReplacement(
            context,
            RideTrackingPage(
              rideId: notification['id'] as int,
              pickupAddress: notification['start'] as String,
              dropoffAddress: notification['end'] as String,
              numberOfPassengers: notification['people'] as int,
              passengerName: notification['passenger_name'] as String?,
              passengerPhone: notification['passenger_phone'] as String?,
              pickupLat: notification['pickup_lat'] != null
                  ? double.tryParse(notification['pickup_lat'].toString())
                  : null,
              pickupLng: notification['pickup_lng'] != null
                  ? double.tryParse(notification['pickup_lng'].toString())
                  : null,
              dropoffLat: notification['dropoff_lat'] != null
                  ? double.tryParse(notification['dropoff_lat'].toString())
                  : null,
              dropoffLng: notification['dropoff_lng'] != null
                  ? double.tryParse(notification['dropoff_lng'].toString())
                  : null,
            ),
          );
        }
      } else {
        _errorService.showError(context, 'Failed to accept ride');
      }
    } catch (e) {
      _errorService.handleError(context, e);
    } finally {
      safeSetState(() => isLoading = false);
    }
  }

  Future<void> _rejectRide(int rideId) async {
    final userData = await _authService.getUserData();
    final driverId = userData?['id']?.toString() ?? 'unknown';
    safeSetState(() => isLoading = true);

    try {
      final success = await _wsController.rideController.rejectRide(
        rideId,
        driverId,
      );
      if (!mounted) return;

      if (success) {
        safeSetState(() {
          notifications.removeWhere((notif) => notif['id'] == rideId);
        });
        _errorService.showSuccess(
          context,
          'Ride rejected - hidden from your list! ❌',
        );
      } else {
        _errorService.showError(context, 'Failed to reject ride');
      }
    } catch (e) {
      _errorService.handleError(context, e);
    } finally {
      safeSetState(() => isLoading = false);
    }
  }

  Future<void> _sendDriverOfflineSilently() async {
    final token = await _authService.getAccessToken();
    if (token == null || token.isEmpty) return;

    try {
      await _apiService.patch(
        DriverEndpoints.status,
        body: {'status': 'offline'},
      );
    } catch (e) {
      Logger.error(
        'Error sending offline status on dispose',
        error: e,
        tag: 'DriverPage',
      );
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
        userType: 'Driver',
        userName: userData?['username'] ?? 'E-Rick Driver',
        userEmail: userData?['email'] ?? 'driver@erick.com',
        accessToken: token,
      ),
    );
  }

  // Handle rides navigation
  Future<void> _handleRidesNavigation() async {
    final authState = await _authService.getAuthState();
    if (!authState.isAuthenticated) {
      if (!mounted) return;
      _errorService.showError(
        context,
        'Please login to view previous rides.',
      );
      return;
    }
    if (!mounted) return;
    AppRouter.push(context, const PreviousRidesPage(isDriver: true));
  }

  void _showBottomSheet(Map<String, dynamic> notif) {
    RideRequestBottomSheet.show(
      context,
      notification: notif,
      isLoading: isLoading,
      onAccept: () => _acceptRide(notif),
      onReject: () => _rejectRide(notif['id'] as int),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('E-Rickshaw Driver'),
        leading: IconButton(
          onPressed: () {
            // Show confirmation dialog
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Logout'),
                content: const Text('Are you sure you want to logout?'),
                actions: [
                  TextButton(
                    onPressed: () => AppRouter.pop(context),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () async {
                      AppRouter.pop(context); // Close dialog
                      // Clear auth data and navigate to splash
                      await AuthService().clearAuthData();
                      if (context.mounted) {
                        AppRouter.pushNamedAndRemoveUntil(
                          context,
                          AppRouter.splash,
                          (route) => false,
                        );
                      }
                    },
                    child: const Text(
                      'Logout',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            );
          },
          icon: const Icon(Icons.logout, color: Colors.red),
          tooltip: 'Logout',
        ),
        actions: [
          // Profile menu button (Profile | Previous Rides)
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
      body: _mapPosition == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Map (top half)
                DriverMapWidget(currentPosition: _mapPosition!),

                // Bottom part (status controls + notifications)
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        // Driver Status Controls
                        DriverStatusControls(
                          isActive: isActive,
                          isLoading: isLoading,
                          onGoOnline: () => _updateDriverStatus(true),
                          onGoOffline: () => _updateDriverStatus(false),
                        ),

                        const SizedBox(height: 16),

                        // Ride Requests Section
                        RideNotificationList(
                          notifications: notifications,
                          isActive: isActive,
                          isLoading: isLoading,
                          errorMessage: errorMessage,
                          onRetry: _loadDriverData,
                          onRefresh: _loadDriverData,
                          onNotificationTap: _showBottomSheet,
                        ),

                        const SizedBox(height: 16), // Extra padding at bottom
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
