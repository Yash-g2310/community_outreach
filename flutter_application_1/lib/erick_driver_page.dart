import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'profile.dart';
// If you plan to show a map, later add:
// import 'package:google_maps_flutter/google_maps_flutter.dart';

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

      // Start periodic location updates
      _startLocationUpdates();
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
      print('Current location: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      print('Error getting current location: $e');
    }
  }

  void _startLocationUpdates() {
    _locationUpdateTimer = Timer.periodic(const Duration(seconds: 10), (
      timer,
    ) async {
      await _updateDriverLocation();
    });
  }

  Future<void> _updateDriverLocation() async {
    print('=== LOCATION UPDATE STARTED ===');

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
      // Load driver profile and nearby rides
      await Future.wait([_fetchDriverProfile(), _fetchNearbyRides()]);
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
      throw e;
    }
  }

  Future<void> _fetchNearbyRides() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/rides/driver/nearby-rides/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> ridesData = data['rides'] ?? [];

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
      } else if (response.statusCode == 400) {
        // Driver not available or no location
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

        // Refresh nearby rides when status changes
        if (active) {
          await _fetchNearbyRides();
        } else {
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
        Uri.parse('$baseUrl/api/rides/rides/$rideId/accept/'),
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
        Uri.parse('$baseUrl/api/rides/rides/$rideId/driver-cancel/'),
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

                            // Navigate to assignment page with real data
                            if (mounted) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => DriverAssignmentPage(
                                    requestId: notif['id'] as int,
                                    pickupLabel: notif['start'] as String,
                                    dropLabel: notif['end'] as String,
                                    pax: notif['people'] as int,
                                    passengerName:
                                        notif['passenger_name'] as String,
                                    passengerPhone:
                                        notif['passenger_phone'] as String,
                                    pickupLat: notif['pickup_lat'],
                                    pickupLng: notif['pickup_lng'],
                                    dropoffLat: notif['dropoff_lat'],
                                    dropoffLng: notif['dropoff_lng'],
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
      backgroundColor: Colors.grey[300],
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              color: Colors.cyan,
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Logout button
                  IconButton(
                    onPressed: () {
                      print('=== NAVIGATION ===');
                      print('Logging out from Driver Dashboard');
                      print('==================');

                      // Show confirmation dialog
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Logout'),
                          content: const Text(
                            'Are you sure you want to logout?',
                          ),
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
                              child: const Text('Logout'),
                            ),
                          ],
                        ),
                      );
                    },
                    icon: const Icon(Icons.logout, color: Colors.white),
                  ),
                  // Title
                  const Expanded(
                    child: Text(
                      'E Rick Driver',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Settings/Profile button
                  IconButton(
                    onPressed: () {
                      print('=== NAVIGATION ===');
                      print('Navigating from Driver Dashboard to Profile');
                      print('==================');

                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ProfilePage(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.person, color: Colors.white),
                  ),
                ],
              ),
            ),

            // Driver info + photo
            Container(
              color: Colors.black,
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (driverProfile != null) ...[
                          Text(
                            'Driver: ${driverProfile!['user']['username']}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Vehicle: ${driverProfile!['vehicle_number']}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            'Rides: ${driverProfile!['user']['completed_rides']}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ] else ...[
                          const Text(
                            'Loading driver details...',
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Container(
                    color: Colors.orange,
                    width: 100,
                    height: 80,
                    child: driverProfile?['user']['profile_picture'] != null
                        ? Image.network(
                            driverProfile!['user']['profile_picture'],
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return const Center(
                                child: Text(
                                  'Photo\nof\ndriver',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.white),
                                ),
                              );
                            },
                          )
                        : const Center(
                            child: Text(
                              'Photo\nof\ndriver',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // Active / Inactive buttons with loading state
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: isLoading ? null : () => _updateDriverStatus(true),
                  icon: Icon(
                    Icons.circle,
                    color: isLoading ? Colors.grey : Colors.green,
                  ),
                  label: Text(isLoading ? 'Updating...' : 'Active'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isActive
                        ? Colors.green[100]
                        : Colors.grey[200],
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: isLoading
                      ? null
                      : () => _updateDriverStatus(false),
                  icon: Icon(
                    Icons.circle,
                    color: isLoading ? Colors.grey : Colors.red,
                  ),
                  label: Text(isLoading ? 'Updating...' : 'Inactive'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: !isActive
                        ? Colors.red[100]
                        : Colors.grey[200],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Notifications Header
            Container(
              width: double.infinity,
              color: Colors.blue[900],
              padding: const EdgeInsets.all(12),
              child: const Text(
                'Notifications',
                style: TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),

            // Scrollable Notifications List with loading and error states
            Expanded(
              child: isLoading
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Loading rides...'),
                        ],
                      ),
                    )
                  : errorMessage != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error, color: Colors.red, size: 48),
                          const SizedBox(height: 16),
                          Text(
                            errorMessage!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.red),
                          ),
                          const SizedBox(height: 16),
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
                              // Rides counter
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(8),
                                color: Colors.blue[50],
                                child: Text(
                                  '${notifications.length} ride request${notifications.length == 1 ? '' : 's'} nearby',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue[800],
                                  ),
                                ),
                              ),
                              // Rides list
                              Expanded(
                                child: ListView.builder(
                                  itemCount: notifications.length,
                                  itemBuilder: (context, index) {
                                    final notif = notifications[index];
                                    return GestureDetector(
                                      onTap: () => _showBottomSheet(notif),
                                      child: Card(
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                        color: Colors.grey[100],
                                        elevation: 3,
                                        child: Padding(
                                          padding: const EdgeInsets.all(12.0),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Text(
                                                    'Ride #${notif['id']}',
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 16,
                                                      color: Colors.blue,
                                                    ),
                                                  ),
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 4,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: Colors.orange,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      '${notif['distance']}m away',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 8),
                                              Row(
                                                children: [
                                                  const Icon(
                                                    Icons.person,
                                                    size: 16,
                                                    color: Colors.grey,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    notif['passenger_name'] ??
                                                        'Unknown',
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Row(
                                                children: [
                                                  const Icon(
                                                    Icons.location_on,
                                                    size: 16,
                                                    color: Colors.green,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Expanded(
                                                    child: Text(
                                                      'From: ${notif['start']}',
                                                      style: const TextStyle(
                                                        fontSize: 14,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Row(
                                                children: [
                                                  const Icon(
                                                    Icons.location_on,
                                                    size: 16,
                                                    color: Colors.red,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Expanded(
                                                    child: Text(
                                                      'To: ${notif['end']}',
                                                      style: const TextStyle(
                                                        fontSize: 14,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Row(
                                                children: [
                                                  const Icon(
                                                    Icons.group,
                                                    size: 16,
                                                    color: Colors.blue,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    '${notif['people']} passenger${notif['people'] == 1 ? '' : 's'}',
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          )
                        : Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.notifications_off,
                                  size: 48,
                                  color: Colors.grey,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'No ride requests nearby',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Stay active to receive new requests',
                                  style: TextStyle(color: Colors.grey),
                                ),
                                const SizedBox(height: 16),
                                ElevatedButton.icon(
                                  onPressed: _loadDriverData,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Refresh'),
                                ),
                              ],
                            ),
                          )
                  : const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.pause_circle,
                            size: 48,
                            color: Colors.grey,
                          ),
                          SizedBox(height: 16),
                          Text(
                            'You are offline',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Set status to Active to receive ride requests',
                            style: TextStyle(color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// NEW SCREEN: shows assignment and will host live map/location
class DriverAssignmentPage extends StatefulWidget {
  final int requestId;
  final String pickupLabel;
  final String dropLabel;
  final int pax;
  final String? passengerName;
  final String? passengerPhone;
  final dynamic pickupLat;
  final dynamic pickupLng;
  final dynamic dropoffLat;
  final dynamic dropoffLng;

  const DriverAssignmentPage({
    super.key,
    required this.requestId,
    required this.pickupLabel,
    required this.dropLabel,
    required this.pax,
    this.passengerName,
    this.passengerPhone,
    this.pickupLat,
    this.pickupLng,
    this.dropoffLat,
    this.dropoffLng,
  });

  @override
  State<DriverAssignmentPage> createState() => _DriverAssignmentPageState();
}

class _DriverAssignmentPageState extends State<DriverAssignmentPage> {
  // TODO: Add GoogleMap controller and live stream subscription here.
  // Example placeholders:
  // GoogleMapController? _mapCtrl;
  // StreamSubscription? _locationSub;

  @override
  void initState() {
    super.initState();
    // TODO: Subscribe to backend stream with widget.requestId to receive rider location updates.
    // Example with Firebase/WS: _locationSub = riderLocationStream(widget.requestId).listen((pos){ setState(...); });
  }

  @override
  void dispose() {
    // _locationSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Assigned Ride')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header/summary card with enhanced passenger info
          Container(
            color: Colors.blueGrey[50],
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Ride #${widget.requestId}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'ACCEPTED',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Passenger info
                if (widget.passengerName != null) ...[
                  Row(
                    children: [
                      const Icon(Icons.person, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        'Passenger: ${widget.passengerName}',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],

                if (widget.passengerPhone != null &&
                    widget.passengerPhone!.isNotEmpty) ...[
                  Row(
                    children: [
                      const Icon(Icons.phone, size: 16),
                      const SizedBox(width: 8),
                      Text('Phone: ${widget.passengerPhone}'),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],

                Row(
                  children: [
                    const Icon(Icons.group, size: 16),
                    const SizedBox(width: 8),
                    Text('Passengers: ${widget.pax}'),
                  ],
                ),
                const SizedBox(height: 8),

                // Location info
                Row(
                  children: [
                    const Icon(
                      Icons.location_on,
                      color: Colors.green,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Pickup: ${widget.pickupLabel}')),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.location_on, color: Colors.red, size: 16),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Drop: ${widget.dropLabel}')),
                  ],
                ),
              ],
            ),
          ),

          // Map placeholder; replace with GoogleMap later
          Expanded(
            child: Container(
              color: Colors.grey[200],
              alignment: Alignment.center,
              child: const Text(
                'Map goes here (driver + rider live markers)',
                textAlign: TextAlign.center,
              ),
            ),
          ),

          // Actions
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      // Arrived → could notify backend
                    },
                    child: const Text('Arrived'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      // Start trip → switch to drop routing, notify backend
                    },
                    child: const Text('Start Trip'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      // Complete trip → pop back to home
                      Navigator.pop(context);
                    },
                    child: const Text('Complete'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
