import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../../config/constants.dart';
import '../profile/profile_page.dart';
import '../../utils/string_utils.dart';
import 'previous_rides.dart';
import 'user_tracking_page.dart';
import 'ride_loading_page.dart';
import '../../services/auth_service.dart';
import '../../services/websocket_service.dart';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';
import '../../services/location_service.dart';
import '../../router/app_router.dart';
import '../../core/mixins/safe_state_mixin.dart';

class UserMapScreen extends StatefulWidget {
  final String? jwtToken;
  final Map<String, dynamic>? userData;
  final String? sessionId;
  final String? csrfToken;
  final String? refreshToken;

  const UserMapScreen({
    super.key,
    this.jwtToken,
    this.sessionId,
    this.csrfToken,
    this.refreshToken,
    this.userData,
  });

  @override
  State<UserMapScreen> createState() => _UserMapScreenState();
}

class _UserMapScreenState extends State<UserMapScreen> with SafeStateMixin {
  LatLng? _currentPosition;
  bool _isLoading = false;
  final _isLoadingDrivers = false;
  final List<Map<String, dynamic>> _nearbyDrivers = [];

  // WebSocket service for ride status updates
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription? _wsSubscription;
  final Set<String> _processedRideEvents = <String>{};
  final ErrorService _errorService = ErrorService();

  // Controllers for text input fields
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropController = TextEditingController();
  final TextEditingController _passengerController = TextEditingController();

  // API Configuration uses centralized base URL from constants

  // Helper method to truncate coordinates to 6 decimal places
  double _truncateCoordinate(double coordinate) {
    // Truncate to 6 decimal places to fit Django model constraints (max_digits=10, decimal_places=6)
    return double.parse(coordinate.toStringAsFixed(6));
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentLocation();
  }

  @override
  void dispose() {
    // Cancel WebSocket subscription safely
    try {
      _wsSubscription?.cancel();
      _wsSubscription = null;
    } catch (e) {
      Logger.error(
        'Error cancelling WebSocket subscription',
        error: e,
        tag: 'UserPage',
      );
    }

    // Dispose controllers
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

      if (widget.jwtToken != null) {
        _connectPassengerSocket();
      }
    } catch (e) {
      Logger.error('Error getting location', error: e, tag: 'UserPage');
    }
  }

  // ============================================================
  // 🔌 Connect to passenger WebSocket for ride status updates
  // ============================================================
  void _connectPassengerSocket() {
    try {
      // Connect using centralized WebSocket service
      _wsService.connectPassenger(
        jwtToken: widget.jwtToken,
        sessionId: widget.sessionId,
        csrfToken: widget.csrfToken,
      );

      // Subscribe to passenger messages
      _wsSubscription = _wsService.passengerMessages.listen((data) {
        if (!mounted) return;
        Logger.websocket("WS RAW → $data", tag: 'UserPage');
        _handlePassengerSocketMessage(data);
      });

      // Subscribe to nearby drivers if we have current position
      if (_currentPosition != null) {
        _wsService.sendPassengerMessage({
          "type": "subscribe_nearby",
          "latitude": _currentPosition!.latitude,
          "longitude": _currentPosition!.longitude,
          "radius": 1500,
        });
        Logger.websocket(
          "Sent Websocket for Nearby Drivers to backend",
          tag: 'UserPage',
        );
      } else {
        Logger.warning(
          "Cannot subscribe_nearby — currentPosition is null",
          tag: 'UserPage',
        );
      }

      Logger.websocket(
        'Passenger WebSocket connected via service (user_page)',
        tag: 'UserPage',
      );
    } catch (e) {
      Logger.error(
        'Failed to connect passenger WebSocket',
        error: e,
        tag: 'UserPage',
      );
    }
  }

  // ============================================================
  // 📨 Handle incoming WebSocket messages
  // ============================================================
  Future<void> _handlePassengerSocketMessage(Map<String, dynamic> data) async {
    try {
      final eventType = data['type'] as String?;
      if (eventType == null) return;

      // Only dedupe ride-related events
      if (eventType.startsWith("ride_")) {
        final rideIdKey = data['ride_id']?.toString() ?? '';
        final dedupeKey = '${eventType}_$rideIdKey';

        if (_processedRideEvents.contains(dedupeKey)) {
          return;
        }
        _processedRideEvents.add(dedupeKey);
      }

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
          AppRouter.pushReplacement(
            context,
            UserTrackingPage(
              jwtToken: widget.jwtToken,
              sessionId: widget.sessionId,
              csrfToken: widget.csrfToken,
              refreshToken: widget.refreshToken,
              userData: widget.userData,
            ),
          );
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
    if (widget.jwtToken == null) {
      _errorService.showError(context, 'Please login first');
      return;
    }

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

    safeSetState(() {
      _isLoading = true;
    });

    try {
      // Prepare ride data with simplified structure
      final rideData = {
        'pickup_latitude': _truncateCoordinate(_currentPosition!.latitude),
        'pickup_longitude': _truncateCoordinate(_currentPosition!.longitude),
        'pickup_address': _pickupController.text.trim(),
        'dropoff_address': _dropController.text.trim(),
        'number_of_passengers': passengers,
      };

      Logger.info('Creating ride request: $rideData', tag: 'UserPage');

      final response = await http.post(
        Uri.parse('$kBaseUrl/api/rides/passenger/request/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
        body: json.encode(rideData),
      );

      Logger.network(
        'Response status: ${response.statusCode}',
        tag: 'UserPage',
      );
      Logger.debug('Response body: ${response.body}', tag: 'UserPage');

      if (response.statusCode == 201) {
        final responseData = json.decode(response.body);
        _errorService.showSuccess(
          context,
          'Ride request created! ID: ${responseData['id']}',
        );

        // Clear form
        _pickupController.clear();
        _dropController.clear();
        _passengerController.clear();

        if (mounted) {
          // Show UI-only loading screen; keep this page's WebSocket
          // subscription active so it can detect server response events
          // (e.g. ride_accepted) and perform the transfer at that time.
          AppRouter.push(
            context,
            RideLoadingPage(
              jwtToken: widget.jwtToken,
              sessionId: widget.sessionId,
              csrfToken: widget.csrfToken,
              refreshToken: widget.refreshToken,
              userData: widget.userData,
              rideId: responseData['id'],
            ),
          );
        }
      } else if (response.statusCode == 400) {
        final errorData = json.decode(response.body);
        _errorService.showError(
          context,
          'Error: ${errorData['error'] ?? 'Bad request'}',
        );
      } else if (response.statusCode == 403) {
        _errorService.showError(
          context,
          'Permission denied. Please login again.',
        );
      } else {
        _errorService.showError(context, 'Unexpected error. Please try again.');
      }
    } catch (e) {
      Logger.error('Network error', error: e, tag: 'UserPage');
      _errorService.showError(
        context,
        'Network error. Please check your connection.',
      );
    } finally {
      safeSetState(() {
        _isLoading = false;
      });
    }
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
                AppRouter.push(
                  context,
                  ProfilePage(
                    userType:
                        widget.userData?['role']?.toString().capitalize() ??
                        'User',
                    userName: widget.userData?['username'] ?? 'E-Rick User',
                    userEmail: widget.userData?['email'] ?? 'user@erick.com',
                    accessToken: widget.jwtToken,
                  ),
                );
              } else if (value == 'rides') {
                if (widget.jwtToken == null || widget.jwtToken!.isEmpty) {
                  _errorService.showError(
                    context,
                    'No access token available. Please login to view previous rides.',
                  );
                  return;
                }
                AppRouter.push(
                  context,
                  PreviousRidesPage(
                    jwtToken: widget.jwtToken!,
                    isDriver: false,
                  ),
                );
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
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.5,
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: _currentPosition!,
                      initialZoom: 16,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.demo_apk',
                        tileProvider: kIsWeb
                            ? CancellableNetworkTileProvider()
                            : NetworkTileProvider(),
                      ),
                      MarkerLayer(
                        markers: [
                          // User's current location marker
                          Marker(
                            point: _currentPosition!,
                            width: 60,
                            height: 60,
                            child: const Icon(
                              Icons.location_pin,
                              color: Colors.red,
                              size: 40,
                            ),
                          ),
                          // Nearby drivers markers
                          ..._nearbyDrivers.map((driver) {
                            return Marker(
                              point: LatLng(
                                driver['latitude'].toDouble(),
                                driver['longitude'].toDouble(),
                              ),
                              width: 80,
                              height: 80,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.green,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      driver['vehicle_number'] ?? 'N/A',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.local_taxi,
                                    color: Colors.green,
                                    size: 30,
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ],
                  ),
                ),

                // Bottom part (inputs + button)
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        // Nearby drivers info
                        if (_nearbyDrivers.isNotEmpty) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.green[50],
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.green[200]!),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.local_taxi,
                                      color: Colors.green,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '${_nearbyDrivers.length} E-Rickshaw${_nearbyDrivers.length > 1 ? 's' : ''} Nearby',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const Spacer(),
                                    if (_isLoadingDrivers) ...[
                                      const SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.5,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                Colors.green,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 6),
                                ...(_nearbyDrivers
                                    .take(2) // Reduced from 3 to 2
                                    .map(
                                      (driver) => Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 3,
                                        ),
                                        child: Text(
                                          '${driver['username']} (${driver['vehicle_number']})',
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      ),
                                    )
                                    .toList()),
                                if (_nearbyDrivers.length > 2)
                                  Text(
                                    'and ${_nearbyDrivers.length - 2} more...',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],

                        TextField(
                          controller: _pickupController,
                          enabled: !_isLoading,
                          decoration: const InputDecoration(
                            labelText: 'Pickup Location',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(
                              Icons.location_on,
                              color: Colors.green,
                            ),
                            contentPadding: EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _dropController,
                          enabled: !_isLoading,
                          decoration: const InputDecoration(
                            labelText: 'Drop Location',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(
                              Icons.location_on,
                              color: Colors.red,
                            ),
                            contentPadding: EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _passengerController,
                          enabled: !_isLoading,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Number of Passengers',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.group, color: Colors.blue),
                            contentPadding: EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: _isLoading ? null : _createRideRequest,
                            icon: _isLoading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                : const Icon(Icons.notification_important),
                            label: Text(
                              _isLoading
                                  ? 'Creating Request...'
                                  : 'Alert Nearby E-Rickshaw',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isLoading ? Colors.grey : null,
                            ),
                          ),
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
