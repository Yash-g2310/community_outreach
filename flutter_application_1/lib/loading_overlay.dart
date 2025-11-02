import 'dart:ui';
import 'package:flutter/material.dart';

class LoadingOverlay extends StatefulWidget {
  const LoadingOverlay({super.key});

  @override
  State<LoadingOverlay> createState() => _LoadingOverlayState();
}

class _LoadingOverlayState extends State<LoadingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(); // 🔁 infinite rotation
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.5), // Direct dark overlay
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            color: Colors.transparent, // Completely transparent
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3), // Darker, more opaque
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.2),
                    width: 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 🔁 Infinite rotating image
                    RotationTransition(
                      turns: _controller,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.1),
                        ),
                        child: Image.asset(
                          'assets/erick.png', // Using available asset
                          width: 64,
                          height: 64,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Please Wait !!',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                        letterSpacing: 0.5,
                        shadows: [
                          Shadow(
                            blurRadius: 8,
                            color: Colors.black87,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
