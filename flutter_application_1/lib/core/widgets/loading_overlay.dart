import 'package:flutter/material.dart';

class LoadingOverlay extends StatelessWidget {
  const LoadingOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Color(0xFF1B2229),
        body: Center(child: MultiPulsingCircles()),
      ),
    );
  }
}

class MultiPulsingCircles extends StatefulWidget {
  const MultiPulsingCircles({super.key});

  @override
  State<MultiPulsingCircles> createState() => _MultiPulsingCirclesState();
}

class _MultiPulsingCirclesState extends State<MultiPulsingCircles>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _scale = Tween<double>(
      begin: 0.95,
      end: 1.1,
    ).animate(CurvedAnimation(curve: Curves.easeInOut, parent: _controller));

    _fade = Tween<double>(
      begin: 0.2,
      end: 0.5,
    ).animate(CurvedAnimation(curve: Curves.easeInOut, parent: _controller));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget buildCircle(double size, double border, Color color) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        return Transform.scale(
          scale: _scale.value,
          child: Opacity(
            opacity: _fade.value,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color, width: border),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // main size controller
    const double base = 200;

    return SizedBox(
      width: base * 2,
      height: base * 2,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // big outer faint ring
          buildCircle(base * 1.6, 2, Colors.white.withValues(alpha: 0.4)),

          // middle ring
          buildCircle(base * 1.3, 2, Colors.white.withValues(alpha: 0.55)),

          // inner bright ring
          buildCircle(base, 3, Colors.white.withValues(alpha: 0.9)),

          // glow around inner ring
          AnimatedBuilder(
            animation: _controller,
            builder: (_, _) {
              return Transform.scale(
                scale: _scale.value,
                child: Container(
                  width: base,
                  height: base,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.6),
                        blurRadius: 25,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          // center circular image
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
    );
  }
}
