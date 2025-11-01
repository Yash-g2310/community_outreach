import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'profile.dart';

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
  final String? accessToken;

  const UserMapScreen({
    super.key,
    this.userName,
    this.userEmail,
    this.userRole,
    this.accessToken,
  });

  @override
  State<UserMapScreen> createState() => _UserMapScreenState();
}

class _UserMapScreenState extends State<UserMapScreen> {
  LatLng? _currentPosition;
  bool _isLoading = false;

  // 👇 Controllers for text input fields
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropController = TextEditingController();
  final TextEditingController _passengerController = TextEditingController();

  // API Configuration
  static const String baseUrl = 'http://localhost:8000';

  @override
  void initState() {
    super.initState();
    _loadCurrentLocation();
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
    } catch (e) {
      debugPrint('Error getting location: $e');
    }
  }

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
      // Prepare ride data
      final rideData = {
        'pickup_latitude': _currentPosition!.latitude,
        'pickup_longitude': _currentPosition!.longitude,
        'pickup_address': _pickupController.text.trim(),
        'dropoff_latitude':
            _currentPosition!.latitude + 0.01, // Simple offset for testing
        'dropoff_longitude': _currentPosition!.longitude + 0.01,
        'dropoff_address': _dropController.text.trim(),
        'number_of_passengers': passengers,
        'broadcast_radius': 5000, // 5km radius
      };

      print('=== RIDE REQUEST ===');
      print('Creating ride request: $rideData');
      print('==================');

      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/rides/request/'),
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
          // Profile icon button
          IconButton(
            onPressed: () {
              print('=== NAVIGATION ===');
              print('Navigating to User Profile');
              print('==================');

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
            },
            icon: const Icon(
              Icons.account_circle,
              size: 28,
              color: Colors.blueGrey,
            ),
            tooltip: 'User Profile',
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
                        ],
                      ),
                    ],
                  ),
                ),

                // Bottom part (inputs + button)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
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
                          ),
                        ),
                        const SizedBox(height: 10),
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
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _passengerController,
                          enabled: !_isLoading,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Number of Passengers',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.group, color: Colors.blue),
                          ),
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: _isLoading ? null : _createRideRequest,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
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
                            minimumSize: const Size(double.infinity, 50),
                            backgroundColor: _isLoading ? Colors.grey : null,
                          ),
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
