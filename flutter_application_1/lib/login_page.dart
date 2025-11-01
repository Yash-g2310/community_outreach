import 'package:flutter/material.dart';
import 'erick_driver_page.dart';
import 'home_page.dart'; // Import user home page
import 'loading_overlay.dart';

void main() {
  runApp(const LoginScreenApp());
}

class LoginScreenApp extends StatelessWidget {
  const LoginScreenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LoginScreen(),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  bool _isLoading = false; // Add loading state

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  void _handleConnect() async {
    // Make async for loading simulation
    final email = _emailController.text.trim();

    // Print data to console for verification
    print('=== LOGIN DATA ===');
    print('Email: $email');
    print('Email length: ${email.length}');
    print('Is email empty: ${email.isEmpty}');
    print('==================');

    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your email'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Show loading overlay
    setState(() {
      _isLoading = true;
    });

    print('=== LOADING ===');
    print('Simulating server authentication...');
    print('================');

    // Simulate server authentication delay
    await Future.delayed(const Duration(seconds: 2));

    // Simulate server response with role based on email
    String userRole = _simulateServerResponse(email);

    // Hide loading overlay
    if (mounted) {
      setState(() {
        _isLoading = false;
      });

      print('=== SERVER RESPONSE ===');
      print('User Role: $userRole');
      print('Email: $email');
      print('=====================');

      // TODO: Send data to server here
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Login successful! Role: $userRole'),
          backgroundColor: Colors.green,
        ),
      );

      // Navigate based on role
      _navigateBasedOnRole(userRole, email);
    }
  }

  // Simulate server response based on email
  String _simulateServerResponse(String email) {
    // For testing purposes, determine role based on email
    if (email.toLowerCase().contains('driver') ||
        email.toLowerCase().contains('erick')) {
      return 'driver';
    } else {
      return 'user';
    }
  }

  // Navigate to appropriate page based on user role
  void _navigateBasedOnRole(String role, String email) {
    print('=== NAVIGATION ===');
    print('Navigating to ${role.toUpperCase()} dashboard');
    print('==================');

    Widget destinationPage;

    if (role == 'driver') {
      destinationPage = const DriverPage();
    } else {
      destinationPage = const UserMapScreen(); // Navigate to user home page
    }

    // Replace current screen (so user can't go back to login)
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => destinationPage),
    );
  }

  void _handleGoogleSignIn() async {
    print('=== GOOGLE SIGN IN ===');
    print('Google Sign-In button pressed');
    print('=====================');

    // Show loading
    setState(() {
      _isLoading = true;
    });

    // Simulate Google Sign-In delay
    await Future.delayed(const Duration(seconds: 1));

    if (mounted) {
      setState(() {
        _isLoading = false;
      });

      // For Google Sign-In, simulate getting user role from Google profile
      // In real implementation, you'd get this from Google user data
      String mockGoogleEmail = "user@gmail.com"; // Simulate user role
      String userRole = _simulateServerResponse(mockGoogleEmail);

      print('=== GOOGLE SERVER RESPONSE ===');
      print('Google User Role: $userRole');
      print('============================');

      // TODO: Implement Google Sign-In authentication
      // For now, simulate successful Google sign-in
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Google Sign-In successful! Role: $userRole'),
          backgroundColor: Colors.blue,
        ),
      );

      // Navigate based on role
      _navigateBasedOnRole(userRole, mockGoogleEmail);
    }
  }

  @override
  Widget build(BuildContext context) {
    final orangeColor = const Color(0xFFFF7A00);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Back button
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                    onPressed: () {
                      print('=== NAVIGATION ===');
                      print('Going back from Login Page to Start Page');
                      print('==================');
                      Navigator.pop(context);
                    },
                  ),
                  const SizedBox(height: 10),

                  const Text(
                    "Log in",
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),

                  const Wrap(
                    children: [
                      Text(
                        "By logging in, you agree to our ",
                        style: TextStyle(fontSize: 14, color: Colors.black54),
                      ),
                      Text(
                        "Terms of Use.",
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.black87,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 30),

                  const Text(
                    "Email",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),

                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    onChanged: (value) {
                      // Print data as user types (optional)
                      print('Email input changed: $value');
                    },
                    decoration: InputDecoration(
                      hintText: "Your email",
                      hintStyle: const TextStyle(color: Colors.black38),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Colors.black12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Colors.black12),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),
                  const Text(
                    "We will send you an e-mail with a login link.",
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  ),

                  const SizedBox(height: 25),

                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleConnect,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: orangeColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: const Text(
                        "Connect",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 25),

                  const Row(
                    children: [
                      Expanded(
                        child: Divider(color: Colors.black26, thickness: 1),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          "Or",
                          style: TextStyle(color: Colors.black54),
                        ),
                      ),
                      Expanded(
                        child: Divider(color: Colors.black26, thickness: 1),
                      ),
                    ],
                  ),

                  const SizedBox(height: 25),

                  // Google Sign-in button
                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.g_mobiledata, size: 24),
                      label: const Text(
                        "Sign in with Google",
                        style: TextStyle(
                          color: Colors.black87,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      onPressed: _isLoading ? null : _handleGoogleSignIn,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.black12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),

                  const SizedBox(height: 25),
                  const Text.rich(
                    TextSpan(
                      text: "For more information, please see our ",
                      style: TextStyle(fontSize: 13, color: Colors.black54),
                      children: [
                        TextSpan(
                          text: "Privacy policy.",
                          style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Loading overlay
          if (_isLoading) const LoadingOverlay(),
        ],
      ),
    );
  }
}
