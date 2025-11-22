import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'erick_driver_page.dart';
import 'user_page.dart';
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

  static const bool _enableLoginDebugLogs = true;

  static const String _loginEndpoint = 'http://localhost:8000/api/auth/login/';
  static const String _sessionBootstrapEndpoint =
      'http://localhost:8000/api/auth/bootstrap-session/';

  // Text controllers for login form
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  void _logLogin(String message, {String tag = 'LOGIN'}) {
    if (!_enableLoginDebugLogs) return;
    debugPrint('[$tag] $message');
  }

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

    final messenger = ScaffoldMessenger.of(context);

    try {
      await _loginWithServer(username, password);
    } catch (error) {
      _logLogin('Login error: $error', tag: 'LOGIN_ERROR');
      messenger.showSnackBar(
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
    final requestId = DateTime.now().millisecondsSinceEpoch;
    final stopwatch = Stopwatch()..start();
    _logLogin(
      '($requestId) LOGIN REQUEST :: username=$username endpoint=$_loginEndpoint',
    );

    try {
      final response = await http.post(
        Uri.parse(_loginEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      stopwatch.stop();
      _logLogin(
        '($requestId) API RESPONSE :: status=${response.statusCode} duration=${stopwatch.elapsedMilliseconds}ms',
      );
      _logLogin('($requestId) Body=${response.body}', tag: 'LOGIN_HTTP');

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);

        // Extract user data from API response
        final userData = responseData['user'];
        final userRole = userData['role'];
        final userName = userData['username'];
        final userEmail = userData['email'];
        final tokens = Map<String, dynamic>.from(responseData['tokens'] ?? {});
        final accessToken = tokens['access']?.toString();
        final refreshToken = tokens['refresh']?.toString();
        if (accessToken == null || accessToken.isEmpty) {
          throw Exception('Login response missing access token');
        }

        final rawCookieHeader = response.headers['set-cookie'];
        String? sessionId = _extractCookieValue(rawCookieHeader, 'sessionid');
        String? csrfToken = _extractCookieValue(rawCookieHeader, 'csrftoken');

        if (sessionId == null || csrfToken == null) {
          _logLogin(
            '($requestId) Session cookies missing from login response; invoking bootstrap endpoint',
            tag: 'SESSION',
          );
          final bootstrapData = await _bootstrapSession(accessToken);
          sessionId ??= bootstrapData['sessionid'];
          csrfToken ??= bootstrapData['csrftoken'];
        }

        if (sessionId == null) {
          throw Exception(
            'Unable to establish session for realtime updates. Please retry login.',
          );
        }
        if (csrfToken == null) {
          _logLogin(
            '($requestId) WARNING :: CSRF token missing even after bootstrap; PATCH/POST endpoints may fail',
            tag: 'LOGIN_COOKIE',
          );
        }

        final String confirmedSessionId = sessionId;
        final String? confirmedCsrfToken = csrfToken;

        final tokenPreview = accessToken.length > 16
            ? '${accessToken.substring(0, 16)}...'
            : accessToken;
        _logLogin(
          '($requestId) LOGIN SUCCESS :: role=$userRole user=$userName email=$userEmail accessPreview=$tokenPreview session=${confirmedSessionId.isNotEmpty} csrf=${confirmedCsrfToken != null}',
        );

        // Show success message
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Welcome back, $userName!'),
              backgroundColor: Colors.green,
            ),
          );

          // Navigate based on role from server response
          _navigateBasedOnRole(
            role: userRole,
            userName: userName,
            userEmail: userEmail,
            accessToken: accessToken,
            extraContext: {
              'sessionId': confirmedSessionId,
              'csrfToken': confirmedCsrfToken,
              'refreshToken': refreshToken,
            },
            rawUserData: Map<String, dynamic>.from(userData ?? {}),
          );
        }
      } else {
        // Handle login failure
        final responseData = jsonDecode(response.body);
        final errorMessage = responseData['error'] ?? 'Login failed';

        _logLogin(
          '($requestId) LOGIN FAILED :: $errorMessage',
          tag: 'LOGIN_FAIL',
        );

        throw Exception(errorMessage);
      }
    } catch (error, stackTrace) {
      _logLogin('($requestId) API ERROR :: ${error.runtimeType} -> $error');
      _logLogin(stackTrace.toString(), tag: 'LOGIN_STACK');

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

  // TODO: Remove this function later as it's only for Chrome Based Testing
  Future<Map<String, String?>> _bootstrapSession(String accessToken) async {
    try {
      final response = await http.post(
        Uri.parse(_sessionBootstrapEndpoint),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
      );

      _logLogin(
        'SESSION BOOTSTRAP :: status=${response.statusCode}',
        tag: 'SESSION',
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'sessionid': data['sessionid']?.toString(),
          'csrftoken': data['csrftoken']?.toString(),
        };
      } else {
        _logLogin('Bootstrap failed body=${response.body}', tag: 'SESSION');
      }
    } catch (error, stackTrace) {
      _logLogin('Bootstrap error: $error', tag: 'SESSION_ERROR');
      _logLogin(stackTrace.toString(), tag: 'SESSION_STACK');
    }

    return {};
  }

  // Navigate to signup page
  void _navigateToSignup() {
    _logLogin('Navigating to Sign Up Page', tag: 'NAVIGATION');

    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SignupPage()),
    );
  }

  // Navigate to appropriate page based on user role
  void _navigateBasedOnRole({
    required String role,
    required String userName,
    String? userEmail,
    String? accessToken,
    Map<String, dynamic>? extraContext,
    Map<String, dynamic>? rawUserData,
  }) {
    _logLogin(
      'Navigating -> ${role.toUpperCase()} (user=$userName, email=${userEmail ?? 'n/a'})',
      tag: 'NAVIGATION',
    );

    Widget destinationPage;

    if (role == 'driver') {
      destinationPage = DriverPage(
        jwtToken: accessToken,
        sessionId: extraContext?['sessionId'] as String?,
        csrfToken: extraContext?['csrfToken'] as String?,
        refreshToken: extraContext?['refreshToken'] as String?,
        userData: {
          'username': userName,
          'email': userEmail,
          'role': role,
          if (rawUserData != null) ...rawUserData,
        },
      );
    } else {
      destinationPage = UserMapScreen(
        userName: userName,
        userEmail: userEmail ?? '',
        userRole: role,
        accessToken: accessToken,
      ); // Navigate to user home page with user data
    }

    // Replace current screen (so user can't go back to login)
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => destinationPage),
    );
  }

  String? _extractCookieValue(String? headerValue, String cookieName) {
    if (headerValue == null) return null;
    final regex = RegExp('${RegExp.escape(cookieName)}=([^;]+)');
    final match = regex.firstMatch(headerValue);
    return match?.group(1);
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
