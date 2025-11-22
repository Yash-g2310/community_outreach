import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'profile.dart';
import 'previous_rides.dart';
import 'utils/socket_channel_factory.dart';

// If LoadingOverlayPage and UserTrackingPage are in other files,
// make sure these imports match your project structure:
import 'package:flutter_application_1/user_tracking_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UserApp());
}

class UserApp extends StatelessWidget {
  const UserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'E-Rick User App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home:
          const UserMapScreen(), // Changed to UserMapScreen since that's the main screen
    );
  }
}

// Add UserHomePage as an alias or wrapper for UserMapScreen
class UserHomePage extends StatelessWidget {
  const UserHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const UserMapScreen();
  }
}

class UserMapScreen extends StatefulWidget {
  final String? userName;
  final String? userEmail;
  final String? userRole;
  final String? sessionId;
  final String? csrfToken;
  final String? jwtToken;
  final String? accessToken;

  const UserMapScreen({
    super.key,
    this.userName,
    this.userEmail,
    this.userRole,
    this.sessionId,
    this.csrfToken,
    this.jwtToken,
    this.accessToken,
  });

  @override
  State<UserMapScreen> createState() => _UserMapScreenState();
}

class _UserMapScreenState extends State<UserMapScreen> {
  LatLng? _currentPosition;
  bool _isLoading = false;
  bool _isLoadingDrivers = false;
  List<Map<String, dynamic>> _nearbyDrivers = [];
  Timer? _driversUpdateTimer;

  // WebSocket for ride status updates
  WebSocketChannel? _passengerSocket;
  StreamSubscription? _socketSubscription;

  // WebSocket for nearby drivers real-time updates
  WebSocketChannel? _nearbyDriversSocket;
  StreamSubscription? _nearbyDriversSubscription;

  // 👇 Controllers for text input fields
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropController = TextEditingController();
  final TextEditingController _passengerController = TextEditingController();

  // API Configuration
  static const String baseUrl = 'http://localhost:8000';

  // Helper method to truncate coordinates to 6 decimal places
  double _truncateCoordinate(double coordinate) {
    // Truncate to 6 decimal places to fit Django model constraints (max_digits=10, decimal_places=6)
    return double.parse(coordinate.toStringAsFixed(6));
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentLocation();

    // Connect to passenger WebSocket for real-time ride status
    if (widget.accessToken != null) {
      _connectPassengerSocket();
      _connectNearbyDriversSocket();
    }
  }

  @override
  void dispose() {
    _driversUpdateTimer?.cancel();
    _socketSubscription?.cancel();
    _passengerSocket?.sink.close();
    _nearbyDriversSubscription?.cancel();
    _nearbyDriversSocket?.sink.close();
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

      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
      });

      print('Current location: ${position.latitude}, ${position.longitude}');

      // Load nearby drivers after getting location
      _loadNearbyDrivers();

      // Real-time updates via WebSocket (no more polling!)
    } catch (e) {
      debugPrint('Error getting location: $e');
    }
  }

  // Fetch nearby drivers from API (initial load only)

  Future<void> _loadNearbyDrivers() async {
    if (_currentPosition == null || widget.accessToken == null || !mounted) {
      return;
    }

    setState(() {
      _isLoadingDrivers = true;
    });

    try {
      final requestData = {
        'latitude': _truncateCoordinate(_currentPosition!.latitude),
        'longitude': _truncateCoordinate(_currentPosition!.longitude),
        'radius': 5000, // 5km radius
      };

      print('=== LOADING NEARBY DRIVERS (${DateTime.now()}) ===');
      print('Request data: $requestData');
      print('==============================');

      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/passenger/nearby-drivers/'),
        headers: {
          'Authorization': 'Bearer ${widget.accessToken}',
          'Content-Type': 'application/json',
        },
        body: json.encode(requestData),
      );

      print('Nearby drivers response status: ${response.statusCode}');
      print('Nearby drivers response body: ${response.body}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final drivers = List<Map<String, dynamic>>.from(
          responseData['drivers'] ?? [],
        );

        if (mounted) {
          setState(() {
            _nearbyDrivers = drivers;
          });
        }

        print('Found ${drivers.length} nearby drivers at ${DateTime.now()}');
        for (var driver in drivers) {
          print(
            'Driver: ${driver['username']} - ${driver['vehicle_number']} at (${driver['latitude']}, ${driver['longitude']}) - ${driver['distance_meters']}m',
          );
        }
      } else {
        print('Failed to load nearby drivers: ${response.statusCode}');
      }
    } catch (e) {
      print('Error loading nearby drivers: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingDrivers = false;
        });
      }
    }
  }

  // ============================================================
  // 🔌 Connect to passenger WebSocket for ride status updates
  // ============================================================
  void _connectPassengerSocket() {
    try {
      final uri = Uri(
        scheme: 'ws',
        host: '127.0.0.1',
        port: 8000,
        path: '/ws/app/',
        queryParameters: {
          if (widget.jwtToken?.isNotEmpty ?? false) 'token': widget.jwtToken!,
          if (widget.sessionId?.isNotEmpty ?? false)
            'sessionid': widget.sessionId!,
          if (widget.csrfToken?.isNotEmpty ?? false)
            'csrftoken': widget.csrfToken!,
        },
      );

      _passengerSocket = createPlatformWebSocket(uri);

      _socketSubscription = _passengerSocket!.stream.listen(
        (message) {
          if (!mounted) return;
          _handlePassengerSocketMessage(message);
        },
        onError: (error) {
          print('⚠️ Passenger WebSocket error: $error');
        },
        onDone: () {
          print('🔌 Passenger WebSocket connection closed');
        },
      );

      print('✅ Passenger WebSocket connected: $uri (user_page)');
    } catch (e) {
      print('❌ Failed to connect passenger WebSocket: $e');
    }
  }

  // ============================================================
  // 📨 Handle incoming WebSocket messages
  // ============================================================
  void _handlePassengerSocketMessage(dynamic message) {
    try {
      final data = jsonDecode(message);
      final eventType = data['type'];

      print('📩 Passenger WS event (user_page): $eventType');

      if (eventType == 'ride_accepted') {
        // Driver accepted the ride - navigate to tracking page
        _handleRideAccepted(data);
      } else if (eventType == 'connection_established') {
        print('✅ WebSocket connection confirmed');
      }
    } catch (e) {
      print('⚠️ Error parsing passenger WebSocket message: $e');
    }
  }

  // ============================================================
  // ✅ Handle ride accepted by driver
  // ============================================================
  void _handleRideAccepted(Map<String, dynamic> data) {
    print('✅ Driver accepted ride — navigating to tracking page');

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => UserTrackingPage(
            accessToken: widget.accessToken!,
            userName: widget.userName,
            userEmail: widget.userEmail,
            userRole: widget.userRole,
          ),
        ),
      );
    }
  }

  // ============================================================
  // 🔌 Connect to nearby drivers WebSocket for real-time updates
  // ============================================================
  void _connectNearbyDriversSocket() {
    try {
      final uri = Uri.parse(
        'ws://127.0.0.1:8000/ws/passenger/nearby-drivers/?sessionid=&csrftoken=',
      );

      _nearbyDriversSocket = createPlatformWebSocket(uri);

      _nearbyDriversSubscription = _nearbyDriversSocket!.stream.listen(
        (message) {
          if (!mounted) return;
          _handleNearbyDriversMessage(message);
        },
        onError: (error) {
          print('⚠️ Nearby drivers WebSocket error: $error');
        },
        onDone: () {
          print('🔌 Nearby drivers WebSocket connection closed');
        },
      );

      print('✅ Nearby drivers WebSocket connected');
    } catch (e) {
      print('❌ Failed to connect nearby drivers WebSocket: $e');
    }
  }

  // ============================================================
  // 📨 Handle nearby drivers WebSocket messages
  // ============================================================
  void _handleNearbyDriversMessage(dynamic message) {
    try {
      final data = jsonDecode(message);
      final eventType = data['type'];

      print('📩 Nearby drivers WS event: $eventType');

      if (eventType == 'driver_status_changed') {
        _handleDriverStatusChanged(data);
      } else if (eventType == 'driver_location_updated') {
        _handleDriverLocationUpdated(data);
      } else if (eventType == 'connection_established') {
        print('✅ Nearby drivers WebSocket connection confirmed');
      }
    } catch (e) {
      print('⚠️ Error parsing nearby drivers WebSocket message: $e');
    }
  }

  // ============================================================
  // Handle driver going online/offline
  // ============================================================
  void _handleDriverStatusChanged(Map<String, dynamic> data) {
    final driverId = data['driver_id'];
    final status = data['status'];
    final latitude = data['latitude'];
    final longitude = data['longitude'];

    print('🚗 Driver $driverId status changed to: $status');

    if (!mounted) return;

    setState(() {
      if (status == 'available' && latitude != null && longitude != null) {
        // Driver went online - check if they're nearby
        if (_currentPosition != null) {
          // Calculate distance
          final distance = _calculateDistance(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
            latitude,
            longitude,
          );

          if (distance <= 5000) {
            // Within 5km - add to list if not already there
            final existingIndex = _nearbyDrivers.indexWhere(
              (d) => d['driver_id'] == driverId,
            );

            if (existingIndex == -1) {
              // Add new driver
              _nearbyDrivers.add({
                'driver_id': driverId,
                'latitude': latitude,
                'longitude': longitude,
                'distance_meters': distance,
              });
              print('➕ Added driver $driverId to nearby list');
            }
          }
        }
      } else {
        // Driver went offline or unavailable - remove from list
        _nearbyDrivers.removeWhere((d) => d['driver_id'] == driverId);
        print('➖ Removed driver $driverId from nearby list');
      }
    });
  }

  // ============================================================
  // Handle driver location update
  // ============================================================
  void _handleDriverLocationUpdated(Map<String, dynamic> data) {
    final driverId = data['driver_id'];
    final latitude = data['latitude'];
    final longitude = data['longitude'];

    if (!mounted || _currentPosition == null) return;

    // Calculate new distance
    final distance = _calculateDistance(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      latitude,
      longitude,
    );

    setState(() {
      final existingIndex = _nearbyDrivers.indexWhere(
        (d) => d['driver_id'] == driverId,
      );

      if (distance <= 5000) {
        // Still within range
        if (existingIndex != -1) {
          // Update existing driver
          _nearbyDrivers[existingIndex]['latitude'] = latitude;
          _nearbyDrivers[existingIndex]['longitude'] = longitude;
          _nearbyDrivers[existingIndex]['distance_meters'] = distance;
        } else {
          // Add new driver
          _nearbyDrivers.add({
            'driver_id': driverId,
            'latitude': latitude,
            'longitude': longitude,
            'distance_meters': distance,
          });
        }
      } else {
        // Moved out of range - remove
        if (existingIndex != -1) {
          _nearbyDrivers.removeAt(existingIndex);
          print('🚗 Driver $driverId moved out of range');
        }
      }
    });
  }

  // ============================================================
  // Calculate distance between two coordinates (in meters)
  // ============================================================
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadius = 6371000; // meters

    final double dLat = _degreesToRadians(lat2 - lat1);
    final double dLon = _degreesToRadians(lon2 - lon1);

    final double a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degreesToRadians(lat1)) *
            math.cos(_degreesToRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return earthRadius * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  // ============================================================
  // Create ride request API call
  Future<void> _createRideRequest() async {
    // Validation
    if (widget.accessToken == null) {
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

    setState(() {
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

      print('=== RIDE REQUEST ===');
      print('Creating ride request: $rideData');
      print('==================');

      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/passenger/request/'),
        headers: {
          'Authorization': 'Bearer ${widget.accessToken}',
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

        // You could navigate to a ride tracking page here
        // Navigator.push(context, MaterialPageRoute(builder: (_) => RideTrackingPage(rideId: responseData['id'])));
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
      setState(() {
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
              onPressed: () {
                print('=== LOGOUT ===');
                print('User logged out');
                print('==============');

                Navigator.of(context).pop(); // Close dialog

                // Navigate back to login page and clear all previous routes
                Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil('/', (Route<dynamic> route) => false);
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
        title: const Text('E-Rickshaw User Page'),
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
                      userType: widget.userRole?.capitalize() ?? 'User',
                      userName: widget.userName ?? 'E-Rick User',
                      userEmail: widget.userEmail ?? 'user@erick.com',
                      accessToken: widget.accessToken,
                    ),
                  ),
                );
              } else if (value == 'rides') {
                if (widget.accessToken == null || widget.accessToken!.isEmpty) {
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
                    builder: (context) =>
                        PreviousRidesPage(jwtToken: widget.accessToken!),
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
                                      '${_nearbyDrivers.length} E-Rickshaw${_nearbyDrivers.length > 1 ? 's' : ''} nearby',
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
                                    ] else ...[
                                      const Icon(
                                        Icons.access_time,
                                        color: Colors.green,
                                        size: 12,
                                      ),
                                      const SizedBox(width: 2),
                                      const Text(
                                        'Auto-updating',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.green,
                                          fontStyle: FontStyle.italic,
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
                                          '${driver['username']} (${driver['vehicle_number']}) - ${driver['distance_meters'].toStringAsFixed(0)}m',
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
