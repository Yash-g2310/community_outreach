import 'dart:ui';
import 'package:flutter/material.dart';
import 'user_page.dart';
import '../../config/api_endpoints.dart';
import '../../config/app_constants.dart';
import '../../services/api_service.dart';
import '../../services/error_service.dart';
import '../../router/app_router.dart';

class RideLoadingPage extends StatefulWidget {
  final String? jwtToken;
  final String? sessionId;
  final String? csrfToken;
  final String? refreshToken;
  final Map<String, dynamic>? userData;
  final int? rideId;

  const RideLoadingPage({
    super.key,
    this.jwtToken,
    this.sessionId,
    this.csrfToken,
    this.refreshToken,
    this.userData,
    this.rideId,
  });

  @override
  State<RideLoadingPage> createState() => _RideLoadingPageState();
}

class _RideLoadingPageState extends State<RideLoadingPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _innerScale;
  late final Animation<double> _outerScale;
  final ErrorService _errorService = ErrorService();
  final ApiService _apiService = ApiService();

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: UIConstants.defaultAnimationDuration,
    )..repeat(reverse: true);

    _innerScale = Tween<double>(
      begin: 0.95,
      end: 1.05,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _outerScale = Tween<double>(
      begin: 1.0,
      end: 1.12,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget buildRing({
    required double size,
    required double border,
    required Animation<double> scale,
    required Animation<double> opacity,
  }) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        return Opacity(
          opacity: opacity.value,
          child: Transform.scale(
            scale: scale.value,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: border),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const double base = 180;

    return Scaffold(
      backgroundColor: const Color(0xFF1B2229),
      body: Stack(
        children: [
          // Solid dark background (match `loading_overlay.dart`)
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: const Color(0xFF1B2229)),
          ),

          // ========= PULSING CIRCLE (top area) =========
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 160),
              child: SizedBox(
                width: base * 1.8,
                height: base * 1.8,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    buildRing(
                      size: base * 1.6,
                      border: 2,
                      scale: _outerScale,
                      opacity: Tween<double>(
                        begin: 0.08,
                        end: 0.18,
                      ).animate(_controller),
                    ),
                    buildRing(
                      size: base * 1.3,
                      border: 2,
                      scale: _outerScale,
                      opacity: Tween<double>(
                        begin: 0.10,
                        end: 0.22,
                      ).animate(_controller),
                    ),
                    buildRing(
                      size: base,
                      border: 3,
                      scale: _innerScale,
                      opacity: Tween<double>(
                        begin: 0.25,
                        end: 0.35,
                      ).animate(_controller),
                    ),

                    AnimatedBuilder(
                      animation: _controller,
                      builder: (_, _) {
                        return Transform.scale(
                          scale: _innerScale.value,
                          child: Container(
                            width: base,
                            height: base,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.white.withValues(alpha: 0.45),
                                  blurRadius: 40,
                                  spreadRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                    ClipOval(
                      child: Image.asset(
                        'assets/erick.png',
                        width: base * 0.85,
                        height: base * 0.85,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ============================================

          // ========= TEXT + CANCEL BUTTON (no box) =========
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 80),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Please Wait !!',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 18,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                    ),
                  ),
                  const SizedBox(height: 24),

                  SizedBox(
                    width: MediaQuery.of(context).size.width * 0.85,
                    child: OutlinedButton(
                      onPressed: () async {
                        // Try to cancel the ride on the backend if we have a rideId
                        if (widget.rideId != null && widget.jwtToken != null) {
                          try {
                            final resp = await _apiService.post(
                              PassengerEndpoints.cancel(widget.rideId!),
                              body: {'reason': 'Cancelled by user'},
                            );

                            if (resp.statusCode >= 200 &&
                                resp.statusCode < 300) {
                              if (!mounted) return;
                              _errorService.showSuccess(
                                context,
                                'Ride cancelled',
                              );
                            } else {
                              if (!mounted) return;
                              _errorService.handleError(
                                context,
                                null,
                                response: resp,
                              );
                            }
                          } catch (e) {
                            if (!mounted) return;
                            _errorService.handleError(context, e);
                          }
                        }
                        // Navigate back to user map regardless
                        if (!mounted) return;

                        AppRouter.pushReplacement(
                          context,
                          UserMapScreen(
                            jwtToken: widget.jwtToken,
                            sessionId: widget.sessionId,
                            csrfToken: widget.csrfToken,
                            refreshToken: widget.refreshToken,
                            userData: widget.userData,
                          ),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white, width: 1.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: Colors.white.withValues(alpha: 0.05),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                          color: Colors.white,
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
