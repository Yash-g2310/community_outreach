import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'erick_driver_page.dart';
import 'home_page.dart';
import 'loading_overlay.dart';
import 'signup_page.dart';

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
  bool _isLoading = false;

  // Text controllers for login form
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // Handle login with username and password
  void _handleLogin() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter both username and password'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // TODO: Implement actual API call to Django backend
      await _loginWithServer(username, password);
    } catch (error) {
      print('Login error: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Login failed: ${error.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Login with Django API
  Future<void> _loginWithServer(String username, String password) async {
    print('=== LOGIN REQUEST ===');
    print('Username: $username');
    print('Password: [hidden]');
    print('API Endpoint: http://localhost:8000/api/auth/login/');
    print('====================');

    try {
      final response = await http.post(
        Uri.parse('http://localhost:8000/api/auth/login/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      print('=== API RESPONSE ===');
      print('Status Code: ${response.statusCode}');
      print('Response Body: ${response.body}');
      print('===================');

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);

        // Extract user data from API response
        final userData = responseData['user'];
        final userRole = userData['role'];
        final userName = userData['username'];
        final userEmail = userData['email'];
        final tokens = responseData['tokens'];

        print('=== LOGIN SUCCESS ===');
        print('User Role: $userRole');
        print('User Name: $userName');
        print('User Email: $userEmail');
        print('Access Token: ${tokens['access'].substring(0, 20)}...');
        print('====================');

        // Show success message
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Welcome back, $userName!'),
              backgroundColor: Colors.green,
            ),
          );

          // Navigate based on role from server response
          _navigateBasedOnRole(userRole, userName, userEmail);
        }
      } else {
        // Handle login failure
        final responseData = jsonDecode(response.body);
        final errorMessage = responseData['error'] ?? 'Login failed';

        print('=== LOGIN FAILED ===');
        print('Error: $errorMessage');
        print('===================');

        throw Exception(errorMessage);
      }
    } catch (error) {
      print('=== API ERROR ===');
      print('Error Type: ${error.runtimeType}');
      print('Error Message: $error');
      print('=================');

      // Re-throw with user-friendly message
      if (error.toString().contains('Connection refused') ||
          error.toString().contains('Failed host lookup')) {
        throw Exception(
          'Cannot connect to server. Please ensure the Django server is running.',
        );
      } else {
        throw Exception(error.toString().replaceAll('Exception: ', ''));
      }
    }
  }

  // Navigate to signup page
  void _navigateToSignup() {
    print('=== NAVIGATION ===');
    print('Navigating to Sign Up Page');
    print('==================');

    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SignupPage()),
    );
  }

  // Navigate to appropriate page based on user role
  void _navigateBasedOnRole(String role, String userName, [String? userEmail]) {
    print('=== NAVIGATION ===');
    print('Navigating to ${role.toUpperCase()} dashboard');
    print('User: $userName');
    if (userEmail != null) print('Email: $userEmail');
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

                  const SizedBox(height: 30),

                  // Username field
                  const Text(
                    "Username",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _usernameController,
                    decoration: InputDecoration(
                      hintText: "Enter your username",
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

                  const SizedBox(height: 20),

                  // Password field
                  const Text(
                    "Password",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      hintText: "Enter your password",
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

                  const SizedBox(height: 30),

                  // Login button
                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF7A00),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: const Text(
                        "Log In",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Divider
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

                  const SizedBox(height: 20),

                  // Sign up button
                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: OutlinedButton(
                      onPressed: _isLoading ? null : _navigateToSignup,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.black12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                        backgroundColor: Colors.white,
                      ),
                      child: const Text(
                        "Create New Account",
                        style: TextStyle(
                          color: Colors.black87,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
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
