import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'utils/socket_channel_factory.dart';
import 'user_tracking_page.dart'; // ✅ ensure this exists
import 'user_page.dart'; // ✅ for navigation back after cancel

class RideLoadingScreen extends StatefulWidget {
  final String accessToken; // ✅ for API call
  final String? userName;
  final String? userEmail;
  final String? userRole;
  final String? sessionId;
  final String? csrfToken;

  const RideLoadingScreen({
    super.key,
    required this.accessToken,
    this.userName,
    this.userEmail,
    this.userRole,
    this.sessionId,
    this.csrfToken,
  });

  @override
  State<RideLoadingScreen> createState() => _RideLoadingScreenState();
}

class _RideLoadingScreenState extends State<RideLoadingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;
  Timer? _rideStatusTimer;
  WebSocketChannel? _passengerSocket;
  StreamSubscription? _socketSubscription;

  @override
  void initState() {
    super.initState();

    // 🔁 start spinner animation
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // � Connect to passenger WebSocket for real-time updates
    _connectPassengerSocket();

    // �🔁 begin background polling (only for driver assignment)
    _startRideStatusPolling();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _rideStatusTimer?.cancel();
    _socketSubscription?.cancel();
    _passengerSocket?.sink.close();
    super.dispose();
  }

  // ============================================================
  // � Connect to passenger WebSocket for real-time updates
  // ============================================================
  void _connectPassengerSocket() {
    try {
      final uri = Uri.parse(
        'ws://127.0.0.1:8000/ws/passenger/ride-status/?sessionid=&csrftoken=',
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

      print('✅ Passenger WebSocket connected');
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

      print('📩 Passenger WS event: $eventType');

      if (eventType == 'no_drivers_available') {
        _handleNoDriversAvailable(data);
      } else if (eventType == 'ride_accepted') {
        // Driver accepted - the polling will handle navigation
        print('✅ Driver accepted ride');
      }
    } catch (e) {
      print('⚠️ Error parsing passenger WebSocket message: $e');
    }
  }

  // ============================================================
  // ❌ Handle no drivers available notification
  // ============================================================
  void _handleNoDriversAvailable(Map<String, dynamic> data) {
    print('❌ No drivers available — navigating back to map');
    _rideStatusTimer?.cancel();
    _socketSubscription?.cancel();
    _passengerSocket?.sink.close();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            data['message'] ??
                'No drivers are available at the moment. Please try again later.',
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => UserMapScreen(
            accessToken: widget.accessToken,
            userName: widget.userName,
            userEmail: widget.userEmail,
            userRole: widget.userRole,
          ),
        ),
      );
    }
  }

  // ============================================================
  // �🔁 Loop: check ride status every 5 seconds (only for driver assignment)
  // ============================================================
  void _startRideStatusPolling() {
    _rideStatusTimer?.cancel();
    _rideStatusTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) _fetchRideStatus();
    });
  }

  // ============================================================
  // 🔍 Get current ride ID for cancellation
  // ============================================================
  Future<String?> _getCurrentRideId() async {
    try {
      final response = await http.get(
        Uri.parse('http://127.0.0.1:8000/api/rides/passenger/current'),
        headers: {
          'Authorization': 'Bearer ${widget.accessToken}',
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
      print('⚠️ Error getting current ride ID: $e');
      return null;
    }
  }

  // ============================================================
  // 🚫 Cancel current ride
  // ============================================================
  Future<bool> _cancelRide() async {
    try {
      // First get the current ride ID
      final rideId = await _getCurrentRideId();

      if (rideId == null) {
        print('❌ No active ride found to cancel');
        return false;
      }

      print('🚫 Attempting to cancel ride $rideId...');

      final response = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/rides/passenger/$rideId/cancel/'),
        headers: {
          'Authorization': 'Bearer ${widget.accessToken}',
          'Content-Type': 'application/json',
        },
      );

      print('📡 Cancel response status: ${response.statusCode}');
      print('📦 Cancel response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print(
          '✅ Ride cancelled successfully: ${data['message'] ?? 'No message'}',
        );
        return true;
      } else {
        print('❌ Failed to cancel ride: ${response.body}');
        return false;
      }
    } catch (e) {
      print('🚨 Error cancelling ride: $e');
      return false;
    }
  }

  // ============================================================
  // 🧭 Fetch ride status from backend
  // ============================================================
  Future<void> _fetchRideStatus() async {
    final navigator = Navigator.of(context);

    try {
      final response = await http.get(
        Uri.parse('http://127.0.0.1:8000/api/rides/passenger/current'),
        headers: {
          'Authorization': 'Bearer ${widget.accessToken}',
          'Content-Type': 'application/json',
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        print('\n==============================');
        print('📦 Ride status data (from RideLoadingScreen):');
        print(jsonEncode(data));
        print('==============================');

        final bool hasActiveRide = data['has_active_ride'] ?? false;
        final bool driverAssigned = data['driver_assigned'] ?? false;

        print('has_active_ride: $hasActiveRide');
        print('driver_assigned: $driverAssigned');

        // ✅ WebSocket handles no_drivers notification, so we only check for driver assignment
        if (hasActiveRide && driverAssigned) {
          print('✅ Driver assigned — navigating to UserTrackingPage');
          _rideStatusTimer?.cancel();
          navigator.pushReplacement(
            MaterialPageRoute(
              builder: (context) => UserTrackingPage(
                accessToken: widget.accessToken,
                userName: widget.userName,
                userEmail: widget.userEmail,
                userRole: widget.userRole,
              ),
            ),
          );
        } else {
          print('⏳ Still waiting for driver assignment...');
        }
      } else {
        print('❌ Failed to fetch ride status: ${response.statusCode}');
        print('Response body: ${response.body}');
      }
    } catch (e) {
      print('⚠️ Error checking ride status: $e');
    }
  }

  // ============================================================
  // 🖼️ UI
  // ============================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 🔹 blurred background
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: Colors.black.withValues(alpha: 0.3)),
          ),

          // 🔹 loading card
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.only(bottom: 80),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RotationTransition(
                    turns: _rotationController,
                    child: Image.asset(
                      'assets/erick.png',
                      width: 80,
                      height: 80,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Please Wait !!',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Cancel button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        print('=== CANCEL BUTTON PRESSED ===');
                        print('User cancelled ride loading');
                        print('============================');

                        final navigator = Navigator.of(context);
                        final messenger = ScaffoldMessenger.of(context);

                        // Show loading indicator
                        showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (BuildContext context) {
                            return AlertDialog(
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

                        if (!mounted) return;

                        // Close loading dialog
                        navigator.pop();

                        if (success) {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('Ride cancelled successfully'),
                              backgroundColor: Colors.green,
                            ),
                          );

                          // Stop polling and navigate back to UserMapScreen
                          _rideStatusTimer?.cancel();
                          navigator.pushReplacement(
                            MaterialPageRoute(
                              builder: (context) => UserMapScreen(
                                userName: widget.userName,
                                userEmail: widget.userEmail,
                                userRole: widget.userRole,
                                accessToken: widget.accessToken,
                              ),
                            ),
                          );
                        } else {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Failed to cancel ride. Please try again.',
                              ),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white, width: 1.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                          color: Colors.black87,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
