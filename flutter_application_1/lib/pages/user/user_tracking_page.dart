import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'user_page.dart'; // for navigation back to user page
import '../../config/constants.dart';
import '../../services/websocket_service.dart';

class UserTrackingPage extends StatefulWidget {
  final String? jwtToken;
  final String? sessionId;
  final String? csrfToken;
  final String? refreshToken;
  final Map<String, dynamic>? userData;

  const UserTrackingPage({
    super.key,
    this.jwtToken,
    this.sessionId,
    this.csrfToken,
    this.refreshToken,
    this.userData,
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
  String? _currentRideId;

  final WebSocketService _wsService = WebSocketService();
  StreamSubscription? _wsSubscription;
  final Set<String> _processedRideEvents = <String>{};

  @override
  void initState() {
    super.initState();

    // Ensure WebSocket is connected (it should already be from user_page)
    if (widget.jwtToken != null) {
      _wsService.connectPassenger(
        jwtToken: widget.jwtToken,
        sessionId: widget.sessionId,
        csrfToken: widget.csrfToken,
      );
    }

    // Subscribe to passenger messages from WebSocket service
    _wsSubscription = _wsService.passengerMessages.listen((data) {
      if (!mounted) return;
      _handleWebSocketMessage(data);
    });

    _setupTracking();
  }

  @override
  void dispose() {
    _sendStopTracking();
    // Cancel local subscription only - WebSocket service persists
    try {
      _wsSubscription?.cancel();
      _wsSubscription = null;
    } catch (e) {
      print('Error cancelling tracking subscription: $e');
    }
    super.dispose();
  }

  Future<void> _setupTracking() async {
    await _getCurrentLocation();
    await _getCurrentRideInfo(); // Get ride ID and initial driver info
    if (_currentRideId != null) {
      _sendStartTracking();
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      if (!mounted) return;

      _safeSetState(() {
        _userPosition = LatLng(pos.latitude, pos.longitude);
      });
    } catch (e) {
      print('Error getting user location: $e');
    }
  }

  // ============================================================
  // Get current ride info (ID + initial driver data)
  // ============================================================
  Future<void> _getCurrentRideInfo() async {
    try {
      final response = await http.get(
        Uri.parse('$kBaseUrl/api/rides/passenger/current/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.jwtToken}',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['has_active_ride'] == true &&
            data['driver_assigned'] == true) {
          final ride = data['ride'];
          final driver = ride['driver'];

          _safeSetState(() {
            _currentRideId = ride['id']?.toString();
            _status = ride['status'] ?? "N/A";
            _username = driver['username'] ?? "N/A";
            _phoneNumber = driver['phone_number'] ?? "N/A";
            _vehicleNumber = driver['vehicle_number'] ?? "N/A";

            final lat = double.tryParse(driver['current_latitude'] ?? "");
            final lng = double.tryParse(driver['current_longitude'] ?? "");
            if (lat != null && lng != null) {
              _driverPosition = LatLng(lat, lng);
            }
          });

          print('Ride ID: $_currentRideId, Driver: $_username');
        }
      }
    } catch (e) {
      print('Error getting ride info: $e');
    }
  }

  // Send start_tracking message to join ride group
  void _sendStartTracking() {
    if (_currentRideId != null) {
      _wsService.sendPassengerMessage({
        'type': 'start_tracking',
        'ride_id': int.tryParse(_currentRideId ?? '') ?? _currentRideId,
      });
      print('Sent start_tracking for ride $_currentRideId');
    }
  }

  // Send stop_tracking message to leave ride group (optional, e.g. on dispose)
  void _sendStopTracking() {
    if (_currentRideId != null) {
      _wsService.sendPassengerMessage({
        'type': 'stop_tracking',
        'ride_id': int.tryParse(_currentRideId ?? '') ?? _currentRideId,
      });
      print('Sent stop_tracking for ride $_currentRideId');
    }
  }

  // ============================================================
  // Get current ride ID for cancellation
  // ============================================================
  Future<String?> _getCurrentRideId() async {
    try {
      final response = await http.get(
        Uri.parse('$kBaseUrl/api/rides/passenger/current'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final bool hasActiveRide = data['has_active_ride'] ?? false;

        if (hasActiveRide) {
          final rideData = data['ride'] ?? {};
          return rideData['id']?.toString();
        }
      }
      return null;
    } catch (e) {
      print('Error getting current ride ID: $e');
      return null;
    }
  }

  // Handle incoming WebSocket messages for ride tracking
  void _handleWebSocketMessage(Map<String, dynamic> data) {
    if (!mounted) return;
    try {
      final eventType = data['type'] as String?;
      if (eventType == null) return;

      // Deduplicate events that may be delivered twice (user_<id> and ride_<id>)
      if (eventType != 'driver_track_location') {
        final rideIdKey = data['ride_id']?.toString() ?? _currentRideId ?? '';
        final dedupeKey = '${eventType}_$rideIdKey';

        if (_processedRideEvents.contains(dedupeKey)) return;
        _processedRideEvents.add(dedupeKey);
      }

      print('Tracking WS message event: $eventType');

      switch (eventType) {
        case 'driver_track_location':
          // update driver position on map
          double? lat;
          double? lng;
          final latRaw = data['latitude'];
          final lngRaw = data['longitude'];
          if (latRaw is num) {
            lat = latRaw.toDouble();
          } else {
            lat = double.tryParse('$latRaw');
          }
          if (lngRaw is num) {
            lng = lngRaw.toDouble();
          } else {
            lng = double.tryParse('$lngRaw');
          }

          if (lat != null && lng != null) {
            _safeSetState(() {
              _driverPosition = LatLng(lat!, lng!);
            });
          }
          break;

        case 'ride_cancelled':
          _safeSetState(() {
            _status = 'cancelled';
          });

          final cancelMsg = data['message'] ?? 'Ride cancelled by driver';

          // Show popup dialog instead of snackbar
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Ride Cancelled'),
              content: Text(cancelMsg),
              actions: [
                TextButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop(); // close dialog

                    // Stop tracking and cancel subscription safely
                    try {
                      _sendStopTracking();
                    } catch (_) {}

                    try {
                      await _wsSubscription?.cancel();
                    } catch (e) {
                      print(
                        'Error cancelling tracking subscription on ride_cancelled: $e',
                      );
                    }
                    if (!mounted) return;
                    // Navigate back to main UserMapScreen
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (context) => UserMapScreen(
                          jwtToken: widget.jwtToken,
                          sessionId: widget.sessionId,
                          csrfToken: widget.csrfToken,
                          refreshToken: widget.refreshToken,
                          userData: widget.userData,
                        ),
                      ),
                    );
                  },
                  child: const Text('OK'),
                ),
              ],
            ),
          );

          break;

        case 'ride_completed':
          _safeSetState(() {
            _status = 'completed';
          });

          // Show a modal dialog so the passenger notices completion
          if (!mounted) return;
          showDialog(
            context: context,
            barrierDismissible: true,
            builder: (ctx) => AlertDialog(
              title: const Text('Ride Completed'),
              content: Text(data['message'] ?? 'Your ride has been completed.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            ),
          ).then((_) async {
            if (!mounted) return;

            // Stop tracking and cancel local subscription before navigating
            try {
              _sendStopTracking();
            } catch (_) {}

            try {
              await _wsSubscription?.cancel();
            } catch (e) {
              print(
                'Error cancelling tracking subscription on ride_completed: $e',
              );
            }
            if (!mounted) return;
            // Navigate back to main UserMapScreen so user lands on the map
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => UserMapScreen(
                  jwtToken: widget.jwtToken,
                  sessionId: widget.sessionId,
                  csrfToken: widget.csrfToken,
                  refreshToken: widget.refreshToken,
                  userData: widget.userData,
                ),
              ),
            );
          });
          break;
        // ignore other events
      }
    } catch (e) {
      print('Error decoding tracking WS message: $e | raw=$data');
    }
  }

  // ============================================================
  // Cancel current ride
  // ============================================================
  Future<bool> _cancelRide() async {
    try {
      // First get the current ride ID
      final rideId = await _getCurrentRideId();

      if (rideId == null) {
        print('No active ride found to cancel');
        return false;
      }

      print('Attempting to cancel ride $rideId...');

      final response = await http.post(
        Uri.parse('$kBaseUrl/api/rides/passenger/$rideId/cancel/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      print('Cancel response status: ${response.statusCode}');
      print('Cancel response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print(
          'Ride cancelled successfully: ${data['message'] ?? 'No message'}',
        );
        return true;
      } else {
        print('Failed to cancel ride: ${response.body}');
        return false;
      }
    } catch (e) {
      print('Error cancelling ride: $e');
      return false;
    }
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
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
            print('Navigating back from tracking to user page');

            // Cancel local subscription only - WebSocket service persists
            _wsSubscription?.cancel();

            // Navigate back to UserMapScreen with proper parameters
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => UserMapScreen(
                  jwtToken: widget.jwtToken,
                  sessionId: widget.sessionId,
                  csrfToken: widget.csrfToken,
                  refreshToken: widget.refreshToken,
                  userData: widget.userData,
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
                                  : _status == 'cancelled' ||
                                        _status == 'no_drivers'
                                  ? Colors.red
                                  : _status == 'pending'
                                  ? Colors.orange
                                  : Colors.blue,
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
                      const SizedBox(height: 16),
                      // Cancel button
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed:
                              (_status == 'completed' || _status == 'cancelled')
                              ? null
                              : () async {
                                  print(
                                    'User cancelled ride from tracking page',
                                  );

                                  // Show confirmation dialog first
                                  final bool?
                                  shouldCancel = await showDialog<bool>(
                                    context: context,
                                    builder: (BuildContext context) {
                                      return AlertDialog(
                                        title: const Text('Cancel Ride?'),
                                        content: const Text(
                                          'Are you sure you want to cancel this ride? The driver has already been assigned.',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text('No, Keep Ride'),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text(
                                              'Yes, Cancel',
                                              style: TextStyle(
                                                color: Colors.red,
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  );

                                  if (!context.mounted) return;

                                  if (shouldCancel != true) return;

                                  // Show loading indicator
                                  showDialog(
                                    context: context,
                                    barrierDismissible: false,
                                    builder: (BuildContext context) {
                                      return const AlertDialog(
                                        content: Row(
                                          children: [
                                            CircularProgressIndicator(),
                                            SizedBox(width: 20),
                                            Text('Cancelling ride...'),
                                          ],
                                        ),
                                      );
                                    },
                                  );

                                  // Attempt to cancel the ride
                                  final success = await _cancelRide();

                                  if (!context.mounted) return;

                                  // Close loading dialog
                                  Navigator.pop(context);

                                  if (success) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Ride cancelled successfully',
                                        ),
                                        backgroundColor: Colors.green,
                                      ),
                                    );

                                    // Cancel local listener and navigate back to UserMapScreen
                                    _wsSubscription?.cancel();

                                    Navigator.pushReplacement(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => UserMapScreen(
                                          jwtToken: widget.jwtToken,
                                          sessionId: widget.sessionId,
                                          csrfToken: widget.csrfToken,
                                          refreshToken: widget.refreshToken,
                                          userData: widget.userData,
                                        ),
                                      ),
                                    );
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Failed to cancel ride. Please try again.',
                                        ),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  }
                                },
                          icon: Icon(
                            Icons.cancel,
                            color:
                                (_status == 'completed' ||
                                    _status == 'cancelled')
                                ? Colors.grey
                                : Colors.red,
                          ),
                          label: Text(
                            (_status == 'completed')
                                ? 'Ride Completed'
                                : (_status == 'cancelled')
                                ? 'Ride Cancelled'
                                : 'Cancel Ride',
                            style: TextStyle(
                              color:
                                  (_status == 'completed' ||
                                      _status == 'cancelled')
                                  ? Colors.grey
                                  : Colors.red,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color:
                                  (_status == 'completed' ||
                                      _status == 'cancelled')
                                  ? Colors.grey
                                  : Colors.red,
                              width: 1.5,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
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
                        tileProvider: kIsWeb
                            ? CancellableNetworkTileProvider()
                            : NetworkTileProvider(),
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
