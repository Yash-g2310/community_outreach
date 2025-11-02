import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'user_tracking_page.dart'; // ✅ ensure this exists

class RideLoadingScreen extends StatefulWidget {
  final String accessToken; // ✅ for API call

  const RideLoadingScreen({super.key, required this.accessToken});

  @override
  State<RideLoadingScreen> createState() => _RideLoadingScreenState();
}

class _RideLoadingScreenState extends State<RideLoadingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;
  Timer? _rideStatusTimer;

  @override
  void initState() {
    super.initState();

    // 🔁 start spinner animation
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // 🔁 begin background polling
    _startRideStatusPolling();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _rideStatusTimer?.cancel();
    super.dispose();
  }

  // ============================================================
  // 🔁 Loop: check ride status every 5 seconds
  // ============================================================
  void _startRideStatusPolling() {
    _rideStatusTimer?.cancel();
    _rideStatusTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) _fetchRideStatus();
    });
  }

  // ============================================================
  // 🧭 Fetch ride status from backend
  // ============================================================
  Future<void> _fetchRideStatus() async {
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

        print('\n==============================');
        print('📦 Ride status data (from RideLoadingScreen):');
        print(jsonEncode(data));
        print('==============================');

        final bool hasActiveRide = data['has_active_ride'] ?? false;
        final bool driverAssigned = data['driver_assigned'] ?? false;

        print('has_active_ride: $hasActiveRide');
        print('driver_assigned: $driverAssigned');

        if (hasActiveRide && driverAssigned && mounted) {
          print('✅ Driver assigned — navigating to UserTrackingPage');
          _rideStatusTimer?.cancel();
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => const UserTrackingPage(),
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
            child: Container(
              color: Colors.black.withValues(alpha: 0.3),
            ),
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
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3),
                ),
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
