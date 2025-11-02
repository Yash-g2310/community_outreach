import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'profile.dart';
import 'ride_tracking_page.dart';

void main() {
  runApp(const ERickDriverApp());
}

class ERickDriverApp extends StatelessWidget {
  final String? jwtToken;
  final Map<String, dynamic>? userData;

  const ERickDriverApp({super.key, this.jwtToken, this.userData});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DriverPage(jwtToken: jwtToken, userData: userData),
    );
  }
}

class DriverPage extends StatefulWidget {
  final String? jwtToken;
  final Map<String, dynamic>? userData;

  const DriverPage({super.key, this.jwtToken, this.userData});

  @override
  State<DriverPage> createState() => _DriverPageState();
}

class _DriverPageState extends State<DriverPage> {
  bool isActive = true;
  bool isLoading = false;
  String? errorMessage;
  Map<String, dynamic>? driverProfile;
  Timer? _locationUpdateTimer;
  Position? _currentPosition;
  LatLng? _mapPosition; // For displaying on map

  // API Configuration
  static const String baseUrl = 'http://localhost:8000';

  List<Map<String, dynamic>> notifications = [];

  @override
  void initState() {
    super.initState();
    _loadDriverData();
    _initializeLocation();
  }

  @override
  void dispose() {
    _locationUpdateTimer?.cancel();
    super.dispose();
  }

  Future<void> _initializeLocation() async {
    try {
      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('Location permissions are denied');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        print('Location permissions are permanently denied');
        return;
      }

      // Get current location
      await _getCurrentLocation();

      // Location updates will be started after loading driver profile
    } catch (e) {
      print('Error initializing location: $e');
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      _currentPosition = position;

      // Update map position
      setState(() {
        _mapPosition = LatLng(position.latitude, position.longitude);
      });

      print('Current location: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      print('Error getting current location: $e');
    }
  }

  void _startLocationUpdates() {
    // Cancel existing timer if any
    _locationUpdateTimer?.cancel();

    _locationUpdateTimer = Timer.periodic(const Duration(seconds: 10), (
      timer,
    ) async {
      await _updateDriverLocation();
    });

    print('Location update timer started');
  }

  void _stopLocationUpdates() {
    _locationUpdateTimer?.cancel();
    _locationUpdateTimer = null;
    print('Location update timer stopped');
  }

  Future<void> _updateDriverLocation() async {
    print('=== LOCATION UPDATE STARTED ===');

    // Check if driver is online before sending location updates
    if (!isActive) {
      print('Driver is offline - skipping location update');
      print('=== LOCATION UPDATE SKIPPED ===');
      return;
    }

    if (_currentPosition == null) {
      print('No current position, getting fresh location...');
      await _getCurrentLocation();
    }

    if (_currentPosition != null) {
      try {
        // Truncate coordinates to 6 decimal places
        double truncatedLatitude = double.parse(
          _currentPosition!.latitude.toStringAsFixed(6),
        );
        double truncatedLongitude = double.parse(
          _currentPosition!.longitude.toStringAsFixed(6),
        );

        print(
          'Sending location update: $truncatedLatitude, $truncatedLongitude',
        );

        // Use the JWT token from widget (same as other API calls)
        String? token = widget.jwtToken;

        if (token != null) {
          print('Token available, making API call...');
          final response = await http.put(
            Uri.parse('$baseUrl/api/rides/driver/location/'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: json.encode({
              'latitude': truncatedLatitude,
              'longitude': truncatedLongitude,
            }),
          );

          print('API Response: ${response.statusCode}');
          if (response.statusCode == 200) {
            print(
              'Location updated successfully: $truncatedLatitude, $truncatedLongitude',
            );
            // Get fresh location for next update
            await _getCurrentLocation();
          } else {
            print('Failed to update location: ${response.statusCode}');
            print('Response: ${response.body}');
          }
        } else {
          print('ERROR: No JWT token available for location update');
        }
      } catch (e) {
        print('Error updating driver location: $e');
      }
    } else {
      print('ERROR: Could not get current position');
    }

    print('=== LOCATION UPDATE FINISHED ===');
  }

  Future<void> _loadDriverData() async {
    if (widget.jwtToken == null) {
      setState(() {
        errorMessage = 'No authentication token found';
      });
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      // Load driver profile first, then nearby rides (need profile for fallback location)
      await _fetchDriverProfile();
      await _fetchNearbyRides();

      // Start location updates if driver is active
      if (isActive) {
        _startLocationUpdates();
      }
    } catch (e) {
      setState(() {
        errorMessage = 'Error loading driver data: $e';
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _fetchDriverProfile() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/rides/driver/profile/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
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
      print('Driver profile error: $e');
      rethrow;
    }
  }

  Future<void> _fetchNearbyRides() async {
    print('=== FETCH NEARBY RIDES STARTED ===');
    print('Driver Profile available: ${driverProfile != null}');
    print('Current Position available: ${_currentPosition != null}');
    print('isActive: $isActive');

    try {
      // Get current position for the API request
      Position? position = _currentPosition;
      if (position == null) {
        try {
          position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
          );
        } catch (e) {
          print('Unable to get current position for nearby rides: $e');
          // Use driver profile location as fallback
          if (driverProfile != null &&
              driverProfile!['current_latitude'] != null &&
              driverProfile!['current_longitude'] != null) {
            final lat = double.tryParse(
              driverProfile!['current_latitude'].toString(),
            );
            final lng = double.tryParse(
              driverProfile!['current_longitude'].toString(),
            );
            if (lat != null && lng != null) {
              print('Using driver profile location: $lat, $lng');
            } else {
              print('No valid location available for nearby rides API');
              setState(() {
                notifications = [];
              });
              return;
            }
          } else {
            print('No location available for nearby rides API');
            setState(() {
              notifications = [];
            });
            return;
          }
        }
      }

      // Prepare request body with location
      final lat =
          position?.latitude ??
          double.tryParse(driverProfile!['current_latitude'].toString());
      final lng =
          position?.longitude ??
          double.tryParse(driverProfile!['current_longitude'].toString());

      // Ensure we have valid coordinates
      if (lat == null || lng == null) {
        print('ERROR: Cannot get valid coordinates - lat: $lat, lng: $lng');
        setState(() {
          notifications = [];
        });
        return;
      }

      // Round to 6 decimal places to match backend expectations
      final requestBody = {
        'latitude': double.parse(lat.toStringAsFixed(6)),
        'longitude': double.parse(lng.toStringAsFixed(6)),
      };

      print('Raw coordinates: lat=$lat, lng=$lng');
      print(
        'Rounded coordinates: lat=${requestBody['latitude']}, lng=${requestBody['longitude']}',
      );

      print(
        'Fetching nearby rides with location: ${requestBody['latitude']}, ${requestBody['longitude']}',
      );
      print('Request body JSON: ${json.encode(requestBody)}');

      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/driver/nearby-rides/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
        body: json.encode(requestBody),
      );

      print('Nearby rides API response: ${response.statusCode}');
      print('Nearby rides API body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> ridesData = data['rides'] ?? [];

        print('Found ${ridesData.length} nearby rides');

        setState(() {
          notifications = ridesData.map<Map<String, dynamic>>((ride) {
            return {
              'id': ride['id'],
              'start': ride['pickup_address'] ?? 'Unknown pickup',
              'end': ride['dropoff_address'] ?? 'Unknown destination',
              'people': ride['number_of_passengers'] ?? 1,
              'distance': ride['distance_from_driver'] ?? 0,
              'passenger_name': ride['passenger']?['username'] ?? 'Unknown',
              'passenger_phone': ride['passenger']?['phone_number'] ?? '',
              'pickup_lat': ride['pickup_latitude'],
              'pickup_lng': ride['pickup_longitude'],
              'dropoff_lat': ride['dropoff_latitude'],
              'dropoff_lng': ride['dropoff_longitude'],
              'requested_at': ride['requested_at'],
            };
          }).toList();
        });

        print('Updated notifications list with ${notifications.length} rides');
        print('Final notifications state: $notifications');
        print('=== NOTIFICATIONS UPDATE COMPLETE ===');
      } else if (response.statusCode == 400) {
        // Driver not available or no location
        print('Driver not available or location issue');
        setState(() {
          notifications = [];
        });
      } else {
        throw Exception('Failed to load nearby rides: ${response.statusCode}');
      }
    } catch (e) {
      print('Nearby rides error: $e');
      // Don't throw here, just set empty notifications
      setState(() {
        notifications = [];
      });
    }
  }

  Future<void> _updateDriverStatus(bool active) async {
    if (widget.jwtToken == null) return;

    setState(() {
      isLoading = true;
    });

    try {
      final response = await http.patch(
        Uri.parse('$baseUrl/api/rides/driver/status/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'status': active ? 'available' : 'offline',
          'current_latitude': 28.5355, // Default Delhi coordinates
          'current_longitude': 77.3910,
        }),
      );

      if (response.statusCode == 200) {
        setState(() {
          isActive = active;
        });

        // Start or stop location updates based on status
        if (active) {
          _startLocationUpdates();
          // Refresh nearby rides when going online
          await _fetchNearbyRides();
        } else {
          _stopLocationUpdates();
          // Clear notifications when going offline
          setState(() {
            notifications = [];
          });
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              active
                  ? 'You are now available for rides'
                  : 'You are now offline',
            ),
            backgroundColor: active ? Colors.green : Colors.orange,
          ),
        );
      } else {
        throw Exception('Failed to update status: ${response.statusCode}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error updating status: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _acceptRide(int rideId) async {
    if (widget.jwtToken == null) return;

    setState(() {
      isLoading = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/handle/$rideId/accept/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        // Remove the accepted ride from notifications
        setState(() {
          notifications.removeWhere((notif) => notif['id'] == rideId);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ride accepted successfully! ✅'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        throw Exception('Failed to accept ride: ${response.statusCode}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error accepting ride: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _rejectRide(int rideId) async {
    if (widget.jwtToken == null) return;

    setState(() {
      isLoading = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/handle/$rideId/driver-cancel/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        // Remove the rejected ride from notifications
        setState(() {
          notifications.removeWhere((notif) => notif['id'] == rideId);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ride rejected successfully! ❌'),
            backgroundColor: Colors.orange,
          ),
        );
      } else {
        throw Exception('Failed to reject ride: ${response.statusCode}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error rejecting ride: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  void _showBottomSheet(Map<String, dynamic> notif) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Ride Request",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),

              // Ride details with real API data
              _buildDetailRow(
                "Passenger:",
                notif['passenger_name'] ?? 'Unknown',
              ),
              _buildDetailRow("Phone:", notif['passenger_phone'] ?? ''),
              _buildDetailRow("Pickup:", notif['start']),
              _buildDetailRow("Drop-off:", notif['end']),
              _buildDetailRow("Passengers:", "${notif['people']}"),
              _buildDetailRow("Distance:", "${notif['distance']}m away"),

              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Accept button with real API call
                  ElevatedButton.icon(
                    onPressed: isLoading
                        ? null
                        : () async {
                            Navigator.pop(context);
                            await _acceptRide(notif['id'] as int);

                            // Navigate to ride tracking page with real data
                            if (mounted) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => RideTrackingPage(
                                    rideId: notif['id'] as int,
                                    pickupAddress: notif['start'] as String,
                                    dropoffAddress: notif['end'] as String,
                                    numberOfPassengers: notif['people'] as int,
                                    passengerName:
                                        notif['passenger_name'] as String,
                                    passengerPhone:
                                        notif['passenger_phone'] as String,
                                    pickupLat: notif['pickup_lat']?.toDouble(),
                                    pickupLng: notif['pickup_lng']?.toDouble(),
                                    dropoffLat: notif['dropoff_lat']
                                        ?.toDouble(),
                                    dropoffLng: notif['dropoff_lng']
                                        ?.toDouble(),
                                    accessToken: widget.jwtToken,
                                    isDriver: true,
                                  ),
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.check_circle, color: Colors.white),
                    label: const Text("Accept"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: isLoading
                        ? null
                        : () async {
                            Navigator.pop(context);
                            await _rejectRide(notif['id'] as int);
                          },
                    icon: const Icon(Icons.cancel, color: Colors.white),
                    label: const Text("Decline"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('E-Rickshaw Driver'),
        leading: IconButton(
          onPressed: () {
            print('=== NAVIGATION ===');
            print('Logging out from Driver Dashboard');
            print('==================');

            // Show confirmation dialog
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Logout'),
                content: const Text('Are you sure you want to logout?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context); // Close dialog
                      // Navigate back to start page and clear all previous routes
                      Navigator.pushNamedAndRemoveUntil(
                        context,
                        '/',
                        (route) => false,
                      );
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
          // Profile icon button
          IconButton(
            onPressed: () {
              print('=== NAVIGATION ===');
              print('Navigating from Driver Dashboard to Profile');
              print('==================');

              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ProfilePage()),
              );
            },
            icon: const Icon(
              Icons.account_circle,
              size: 28,
              color: Colors.blueGrey,
            ),
            tooltip: 'Driver Profile',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _mapPosition == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Map (top half)
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.5,
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: _mapPosition!,
                      initialZoom: 16,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.erick_driver',
                      ),
                      MarkerLayer(
                        markers: [
                          // Driver's current location marker
                          Marker(
                            point: _mapPosition!,
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
                                    color: Colors.blue,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'You',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.local_taxi,
                                  color: Colors.blue,
                                  size: 35,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Bottom part (status controls + notifications)
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        // Driver Status Controls
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isActive ? Colors.green[50] : Colors.red[50],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isActive
                                  ? Colors.green[200]!
                                  : Colors.red[200]!,
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.circle,
                                    color: isActive ? Colors.green : Colors.red,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    isActive
                                        ? 'Online - Available for rides'
                                        : 'Offline',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: isActive
                                          ? Colors.green[800]
                                          : Colors.red[800],
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: isLoading
                                          ? null
                                          : () => _updateDriverStatus(true),
                                      icon: Icon(
                                        Icons.circle,
                                        color: isLoading
                                            ? Colors.grey
                                            : Colors.green,
                                        size: 18,
                                      ),
                                      label: Text(
                                        isLoading ? 'Updating...' : 'Go Online',
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: isActive
                                            ? Colors.green[100]
                                            : null,
                                        foregroundColor: isActive
                                            ? Colors.green[800]
                                            : null,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: isLoading
                                          ? null
                                          : () => _updateDriverStatus(false),
                                      icon: Icon(
                                        Icons.circle,
                                        color: isLoading
                                            ? Colors.grey
                                            : Colors.red,
                                        size: 18,
                                      ),
                                      label: Text(
                                        isLoading
                                            ? 'Updating...'
                                            : 'Go Offline',
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: !isActive
                                            ? Colors.red[100]
                                            : null,
                                        foregroundColor: !isActive
                                            ? Colors.red[800]
                                            : null,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),

                        // Ride Requests Section
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.blue[200]!),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Header
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.blue[700],
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(12),
                                    topRight: Radius.circular(12),
                                  ),
                                ),
                                child: const Text(
                                  'Ride Requests',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),

                              // Content
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: isLoading
                                    ? const Center(
                                        child: Column(
                                          children: [
                                            CircularProgressIndicator(),
                                            SizedBox(height: 8),
                                            Text('Loading rides...'),
                                          ],
                                        ),
                                      )
                                    : errorMessage != null
                                    ? Center(
                                        child: Column(
                                          children: [
                                            const Icon(
                                              Icons.error,
                                              color: Colors.red,
                                              size: 32,
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              errorMessage!,
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                color: Colors.red,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            ElevatedButton(
                                              onPressed: _loadDriverData,
                                              child: const Text('Retry'),
                                            ),
                                          ],
                                        ),
                                      )
                                    : isActive
                                    ? notifications.isNotEmpty
                                          ? Column(
                                              children: [
                                                // Requests counter
                                                Container(
                                                  width: double.infinity,
                                                  padding: const EdgeInsets.all(
                                                    8,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.orange[100],
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    '${notifications.length} ride request${notifications.length == 1 ? '' : 's'} nearby',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: Colors.orange[800],
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                // Requests list
                                                ...notifications
                                                    .map(
                                                      (notif) => Card(
                                                        margin:
                                                            const EdgeInsets.only(
                                                              bottom: 8,
                                                            ),
                                                        child: ListTile(
                                                          leading: CircleAvatar(
                                                            backgroundColor:
                                                                Colors.blue,
                                                            child: Text(
                                                              '#${notif['id']}',
                                                              style: const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 12,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                            ),
                                                          ),
                                                          title: Text(
                                                            notif['passenger_name'] ??
                                                                'Unknown',
                                                            style:
                                                                const TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                          ),
                                                          subtitle: Column(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            children: [
                                                              Text(
                                                                'From: ${notif['start']}',
                                                              ),
                                                              Text(
                                                                'To: ${notif['end']}',
                                                              ),
                                                              Text(
                                                                'Passengers: ${notif['people']} • ${notif['distance']}m away',
                                                              ),
                                                            ],
                                                          ),
                                                          trailing: Container(
                                                            padding:
                                                                const EdgeInsets.symmetric(
                                                                  horizontal: 8,
                                                                  vertical: 4,
                                                                ),
                                                            decoration:
                                                                BoxDecoration(
                                                                  color: Colors
                                                                      .green,
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        12,
                                                                      ),
                                                                ),
                                                            child: const Text(
                                                              'TAP',
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 10,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                            ),
                                                          ),
                                                          onTap: () =>
                                                              _showBottomSheet(
                                                                notif,
                                                              ),
                                                        ),
                                                      ),
                                                    )
                                                    .toList(),
                                              ],
                                            )
                                          : Center(
                                              child: Column(
                                                children: [
                                                  const Icon(
                                                    Icons.notifications_off,
                                                    size: 32,
                                                    color: Colors.grey,
                                                  ),
                                                  const SizedBox(height: 8),
                                                  const Text(
                                                    'No ride requests nearby',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  const Text(
                                                    'Stay online to receive new requests',
                                                    style: TextStyle(
                                                      color: Colors.grey,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  ElevatedButton.icon(
                                                    onPressed: _loadDriverData,
                                                    icon: const Icon(
                                                      Icons.refresh,
                                                      size: 16,
                                                    ),
                                                    label: const Text(
                                                      'Refresh',
                                                    ),
                                                    style: ElevatedButton.styleFrom(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                            vertical: 8,
                                                          ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            )
                                    : const Center(
                                        child: Column(
                                          children: [
                                            Icon(
                                              Icons.pause_circle,
                                              size: 32,
                                              color: Colors.grey,
                                            ),
                                            SizedBox(height: 8),
                                            Text(
                                              'You are offline',
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              'Go online to receive ride requests',
                                              style: TextStyle(
                                                color: Colors.grey,
                                                fontSize: 12,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
                                        ),
                                      ),
                              ),
                            ],
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
