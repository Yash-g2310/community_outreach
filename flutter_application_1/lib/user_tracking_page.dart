import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'user_page.dart'; // ✅ for navigation back to user page

class UserTrackingPage extends StatefulWidget {
  final String accessToken;
  final String? userName;
  final String? userEmail;
  final String? userRole;

  const UserTrackingPage({
    super.key,
    required this.accessToken,
    this.userName,
    this.userEmail,
    this.userRole,
  });

  @override
  State<UserTrackingPage> createState() => _UserTrackingPageState();
}

class _UserTrackingPageState extends State<UserTrackingPage> {
  LatLng? _userPosition;
  LatLng? _driverPosition;

  String _status = "Loading...";
  String _username = "-";
  String _phoneNumber = "-";
  String _vehicleNumber = "-";

  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    _initializeTracking();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  Future<void> _initializeTracking() async {
    await _getUserLocation();
    _fetchDriverLocation();
    _updateTimer = Timer.periodic(
      const Duration(seconds: 5),
      (timer) => _fetchDriverLocation(),
    );
  }

  Future<void> _getUserLocation() async {
    try {
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        _userPosition = LatLng(pos.latitude, pos.longitude);
      });
    } catch (e) {
      print('Error getting user location: $e');
    }
  }

  Future<void> _fetchDriverLocation() async {
    try {
      final response = await http.get(
        Uri.parse('http://127.0.0.1:8000/api/rides/passenger/current/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.accessToken}',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['has_active_ride'] == true &&
            data['driver_assigned'] == true) {
          final driver = data['ride']['driver'];

          setState(() {
            _status = data['status'] ?? "N/A";
            _username = driver['username'] ?? "N/A";
            _phoneNumber = driver['phone_number'] ?? "N/A";
            _vehicleNumber = driver['vehicle_number'] ?? "N/A";

            final lat = double.tryParse(driver['current_latitude'] ?? "");
            final lng = double.tryParse(driver['current_longitude'] ?? "");
            if (lat != null && lng != null) {
              _driverPosition = LatLng(lat, lng);
            }
          });
        }
      } else {
        print("Error fetching driver location: ${response.statusCode}");
      }
    } catch (e) {
      print("Exception: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Tracking'),
        backgroundColor: Colors.blueAccent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            print('=== BACK TO USER PAGE ===');
            print('Navigating from tracking to user page');
            print('========================');

            // Stop the update timer
            _updateTimer?.cancel();

            // Navigate back to UserMapScreen with proper parameters
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => UserMapScreen(
                  userName: widget.userName,
                  userEmail: widget.userEmail,
                  userRole: widget.userRole,
                  accessToken: widget.accessToken,
                ),
              ),
            );
          },
        ),
      ),
      body: _userPosition == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ----------- RIDE DETAILS HEADER ------------
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    border: Border(
                      bottom: BorderSide(color: Colors.blue[200]!),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header row
                      Row(
                        children: [
                          const Icon(Icons.local_taxi, color: Colors.blue),
                          const SizedBox(width: 8),
                          const Text(
                            'Ride Details',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _status == 'completed'
                                  ? Colors.green
                                  : _status == 'cancelled'
                                  ? Colors.red
                                  : Colors.orange,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _status.toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.person, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Driver: $_username')),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.phone, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Phone: $_phoneNumber')),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.directions_car, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Vehicle: $_vehicleNumber')),
                        ],
                      ),
                    ],
                  ),
                ),

                // ------------------- MAP SECTION -------------------
                Expanded(
                  flex: 1,
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: _userPosition!,
                      initialZoom: 14,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.erick_app',
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _userPosition!,
                            width: 80,
                            height: 80,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(
                                  Icons.person_pin_circle,
                                  color: Colors.green,
                                  size: 35,
                                ),
                                Text(
                                  "You",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 10,
                                    color: Colors.green,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_driverPosition != null)
                            Marker(
                              point: _driverPosition!,
                              width: 80,
                              height: 80,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(
                                    Icons.local_taxi,
                                    color: Colors.blue,
                                    size: 35,
                                  ),
                                  Text(
                                    "Driver",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 10,
                                      color: Colors.blue,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
