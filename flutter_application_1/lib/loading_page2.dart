import 'dart:ui';
import 'package:flutter/material.dart';
import 'user_page.dart';

class RideLoadingScreen extends StatefulWidget {
  final String? jwtToken;
  final String? sessionId;
  final String? csrfToken;
  final String? refreshToken;
  final Map<String, dynamic>? userData;

  const RideLoadingScreen({
    super.key,
    this.jwtToken,
    this.sessionId,
    this.csrfToken,
    this.refreshToken,
    this.userData,
  });

  @override
  State<RideLoadingScreen> createState() => _RideLoadingScreenState();
}

class _RideLoadingScreenState extends State<RideLoadingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();

    // 🔁 start spinner animation
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // No socket handling here — this screen is purely a UI placeholder
    // while `user_page` continues to listen for ride events and
    // navigates to `UserTrackingPage` when the server accepts the ride.
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
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
                      onPressed: () {
                        // UI-only cancel: simply navigate back to the map screen.
                        print('=== CANCEL BUTTON PRESSED (UI) ===');
                        Navigator.of(context).pushReplacement(
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
