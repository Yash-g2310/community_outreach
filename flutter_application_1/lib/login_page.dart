import 'package:flutter/material.dart';
// import 'package:google_sign_in/google_sign_in.dart'; // Commented for OAuth bypass
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
  bool _isLoading = false; // Add loading state

  // Google Sign-In instance (commented out for bypass)
  // final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email', 'profile']);  @override
  void dispose() {
    super.dispose();
  }

  // Function to send user data to your server
  Future<void> sendToServer({
    required String email,
    required String username,
    required String role,
  }) async {
    print('=== SENDING TO SERVER ===');
    print('Preparing to send data to server:');
    print('Email: $email');
    print('Username: $username');
    print('Role: $role');
    print('========================');

    try {
      // TODO: Replace with your actual server endpoint
      // Example HTTP POST request:
      /*
      final response = await http.post(
        Uri.parse('https://your-server.com/api/auth/google'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'username': username,
          'role': role,
          'login_method': 'google_oauth',
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      
      if (response.statusCode == 200) {
        print('Successfully sent data to server');
        return jsonDecode(response.body);
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
      */

      // For now, just simulate server delay
      await Future.delayed(const Duration(milliseconds: 500));
      print('✅ Data successfully sent to server (simulated)');
    } catch (error) {
      print('❌ Error sending data to server: $error');
      rethrow;
    }
  }

  void _handleGoogleSignIn() async {
    print('=== GOOGLE SIGN IN ===');
    print('Google Sign-In button pressed');
    print('=====================');

    // Show loading
    setState(() {
      _isLoading = true;
    });

    // Simulate authentication delay
    await Future.delayed(const Duration(seconds: 1));

    if (mounted) {
      setState(() {
        _isLoading = false;
      });

      // Simulate user data (bypass OAuth)
      const String mockEmail = "testuser@gmail.com";
      const String mockDisplayName = "Test User";

      print('=== SIMULATED USER DATA ===');
      print('Email: $mockEmail');
      print('Username: $mockDisplayName');
      print('========================');

      // Determine user role based on email
      String userRole = _simulateServerResponse(mockEmail);

      print('=== SERVER RESPONSE ===');
      print('User Role: $userRole');
      print('Email: $mockEmail');
      print('Username: $mockDisplayName');
      print('=====================');

      // Send to server (simulated)
      await sendToServer(
        email: mockEmail,
        username: mockDisplayName,
        role: userRole,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Welcome $mockDisplayName! Role: $userRole'),
          backgroundColor: Colors.green,
        ),
      );

      // Navigate based on role
      _navigateBasedOnRole(userRole, mockEmail);
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

  @override
  Widget build(BuildContext context) {
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

                  const SizedBox(height: 40),

                  // Welcome message
                  const Text(
                    "Sign in with your Google account to continue",
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.black87,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 30),

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
