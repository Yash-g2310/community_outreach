import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
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
import '../../router/app_router.dart';

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

class _UserMapScreenState extends State<UserMapScreen> {
  LatLng? _currentPosition;
  bool _isLoading = false;
  final _isLoadingDrivers = false;
  final List<Map<String, dynamic>> _nearbyDrivers = [];

  // WebSocket service for ride status updates
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription? _wsSubscription;
  final Set<String> _processedRideEvents = <String>{};

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
      print('Error cancelling WebSocket subscription: $e');
    }

    // Dispose controllers
    _pickupController.dispose();
    _dropController.dispose();
    _passengerController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) throw Exception('Location services are disabled.');

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception('Location permission denied.');
        }
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception('Location permissions are permanently denied.');
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      _safeSetState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
      });

      print('Current location: ${position.latitude}, ${position.longitude}');

      if (widget.jwtToken != null) {
        _connectPassengerSocket();
      }
    } catch (e) {
      debugPrint('Error getting location: $e');
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
        print("WS RAW → $data");
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
        print("Sent Websocket for Nearby Drivers to backend");
      } else {
        print("Cannot subscribe_nearby — currentPosition is null");
      }

      print('Passenger WebSocket connected via service (user_page)');
    } catch (e) {
      print('Failed to connect passenger WebSocket: $e');
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

      print('Passenger WS event on user_page: $eventType');

      switch (eventType) {
        case 'ride_accepted':
          // Driver accepted the ride. Navigate to tracking page.
          // WebSocket service persists, so no transfer needed.
          print('Driver accepted ride (user_page) — opening tracking page');

          // If a loading screen is on top, pop it first so replacement
          // correctly shows the tracking page.
          if (Navigator.canPop(context)) {
            Navigator.pop(context);
          }

          // Navigate to tracking page - WebSocket service will handle messages
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => UserTrackingPage(
                jwtToken: widget.jwtToken,
                sessionId: widget.sessionId,
                csrfToken: widget.csrfToken,
                refreshToken: widget.refreshToken,
                userData: widget.userData,
              ),
            ),
          );
          break;

        case 'ride_cancelled':
          // If a loading screen (RideLoadingPage) is on top, close it
          if (Navigator.canPop(context)) {
            try {
              Navigator.pop(context);
            } catch (e) {
              // Logger would be better but keeping print for now to avoid circular dependency
              // ignore: avoid_print
              print('Warning popping loading screen on ride_cancelled: $e');
            }
          }
          final String cancelMsg = data['message'] ?? 'Ride was cancelled.';
          _showErrorDialog('Ride Cancelled', cancelMsg);
          break;

        case 'ride_expired':
          if (Navigator.canPop(context)) {
            try {
              Navigator.pop(context);
            } catch (e) {
              print('Warning popping loading screen on ride_expired: $e');
            }
          }
          final String expiredMsg =
              data['message'] ??
              'No driver accepted the request. Try again later.';
          _showErrorDialog('Ride Expired', expiredMsg);
          break;

        case 'no_drivers_available':
          if (Navigator.canPop(context)) {
            try {
              Navigator.pop(context);
            } catch (e) {
              print(
                'Warning popping loading screen on no_drivers_available: $e',
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
          print('Unhandled passenger WS event: $eventType');
      }
    } catch (e) {
      print('Error parsing passenger WebSocket message: $e');
    }
  }

  // ============================================================
  // Handle driver going online/offline
  // ============================================================
  void _handleDriverStatusChanged(Map<String, dynamic> data) {
    final driverId = int.tryParse("${data['driver_id']}");
    final status = data['status'];

    if (driverId == null || !mounted) return;

    print("Driver $driverId status changed → $status");

    // Only action needed: remove driver if explicitly offline
    if (status == "offline" || status == "busy") {
      _safeSetState(() {
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
      print("Ignoring invalid location update.");
      return;
    }

    final String username = data['username']?.toString() ?? "Driver $driverId";
    final String vehicleNumber =
        data['vehicle_number']?.toString() ??
        data['vehicle_no']?.toString() ??
        "N/A";

    _safeSetState(() {
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
      _showErrorSnackBar('Please login first');
      return;
    }

    if (_pickupController.text.trim().isEmpty) {
      _showErrorSnackBar('Please enter pickup location');
      return;
    }

    if (_dropController.text.trim().isEmpty) {
      _showErrorSnackBar('Please enter drop location');
      return;
    }

    if (_passengerController.text.trim().isEmpty) {
      _showErrorSnackBar('Please enter number of passengers');
      return;
    }

    final int passengers = int.tryParse(_passengerController.text.trim()) ?? 0;
    if (passengers <= 0) {
      _showErrorSnackBar('Please enter valid number of passengers');
      return;
    }

    if (_currentPosition == null) {
      _showErrorSnackBar('Location not available. Please wait and try again.');
      return;
    }

    _safeSetState(() {
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

      print('Creating ride request: $rideData');

      final response = await http.post(
        Uri.parse('$kBaseUrl/api/rides/passenger/request/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
        body: json.encode(rideData),
      );

      print('Response status: ${response.statusCode}');
      print('Response body: ${response.body}');

      if (response.statusCode == 201) {
        final responseData = json.decode(response.body);
        _showSuccessSnackBar('Ride request created! ID: ${responseData['id']}');

        // Clear form
        _pickupController.clear();
        _dropController.clear();
        _passengerController.clear();

        if (mounted) {
          // Show UI-only loading screen; keep this page's WebSocket
          // subscription active so it can detect server response events
          // (e.g. ride_accepted) and perform the transfer at that time.
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RideLoadingPage(
                jwtToken: widget.jwtToken,
                sessionId: widget.sessionId,
                csrfToken: widget.csrfToken,
                refreshToken: widget.refreshToken,
                userData: widget.userData,
                rideId: responseData['id'],
              ),
            ),
          );
        }
      } else if (response.statusCode == 400) {
        final errorData = json.decode(response.body);
        _showErrorSnackBar('Error: ${errorData['error'] ?? 'Bad request'}');
      } else if (response.statusCode == 403) {
        _showErrorSnackBar('Permission denied. Please login again.');
      } else {
        _showErrorSnackBar('Unexpected error. Please try again.');
      }
    } catch (e) {
      print('Network error: $e');
      _showErrorSnackBar('Network error. Please check your connection.');
    } finally {
      _safeSetState(() {
        _isLoading = false;
      });
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 4),
      ),
    );
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
                print('User Logged out');

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

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
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
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ProfilePage(
                      userType:
                          widget.userData?['role']?.toString().capitalize() ??
                          'User',
                      userName: widget.userData?['username'] ?? 'E-Rick User',
                      userEmail: widget.userData?['email'] ?? 'user@erick.com',
                      accessToken: widget.jwtToken,
                    ),
                  ),
                );
              } else if (value == 'rides') {
                if (widget.jwtToken == null || widget.jwtToken!.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'No access token available. Please login to view previous rides.',
                      ),
                    ),
                  );
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => PreviousRidesPage(
                      jwtToken: widget.jwtToken!,
                      isDriver: false,
                    ),
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
