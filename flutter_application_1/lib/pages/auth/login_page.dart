import 'package:flutter/material.dart';
import '../../config/api_endpoints.dart';
import 'dart:convert';
import '../driver/driver_page.dart';
import '../user/user_page.dart';
import '../../core/widgets/loading_overlay.dart';
import '../../services/auth_service.dart';
import '../../services/api_service.dart';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';
import '../../utils/validators.dart';
import '../../router/app_router.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = false;

  // Form key for validation
  final _formKey = GlobalKey<FormState>();

  // Text controllers for login form
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  final ErrorService _errorService = ErrorService();
  final ApiService _apiService = ApiService();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // Handle login with username and password
  void _handleLogin() async {
    // Validate form
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    setState(() {
      _isLoading = true;
    });

    try {
      await _loginWithServer(username, password);
    } catch (error) {
      Logger.error('Login error', error: error, tag: 'Login');
      _errorService.handleError(context, error);
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
    Logger.info(
      '($requestId) Login Request :: username=$username endpoint=${AuthEndpoints.login}',
      tag: 'Login',
    );

    try {
      final response = await _apiService.post(
        AuthEndpoints.login,
        body: {'username': username, 'password': password},
        requiresAuth: false,
      );

      stopwatch.stop();
      Logger.network(
        '($requestId) API Response :: status=${response.statusCode}',
        tag: 'Login',
      );
      Logger.debug('($requestId) Body=${response.body}', tag: 'Login');

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

        final tokenPreview = accessToken.length > 16
            ? '${accessToken.substring(0, 16)}...'
            : accessToken;
        Logger.info(
          '($requestId) Login Success :: role=$userRole user=$userName accessPreview=$tokenPreview',
          tag: 'Login',
        );

        // Save authentication data to AuthService
        final authService = AuthService();
        await authService.saveAuthData(
          accessToken: accessToken,
          refreshToken: refreshToken,
          userData: Map<String, dynamic>.from(userData ?? {}),
        );

        // Show success message
        if (mounted) {
          _errorService.showSuccess(context, 'Welcome Back, $userName!');

          // Navigate based on role from server response
          _navigateBasedOnRole(
            role: userRole,
            userName: userName,
            userEmail: userEmail,
            accessToken: accessToken,
            extraContext: {'refreshToken': refreshToken},
            rawUserData: Map<String, dynamic>.from(userData ?? {}),
          );
        }
      } else {
        // Handle login failure
        final responseData = jsonDecode(response.body);
        final errorMessage = responseData['error'] ?? 'Login failed';

        Logger.warning(
          '($requestId) Login Failed :: $errorMessage',
          tag: 'Login',
        );

        throw Exception(errorMessage);
      }
    } catch (error, stackTrace) {
      Logger.error(
        '($requestId) API Error :: ${error.runtimeType} -> $error',
        error: error,
        tag: 'Login',
      );
      Logger.debug('($requestId) StackTrace: $stackTrace', tag: 'Login');

      // Re-throw to be handled by caller
      rethrow;
    }
  }

  // Navigate to signup page
  void _navigateToSignup() {
    Logger.info('Navigating to Sign Up Page', tag: 'Login');

    AppRouter.pushNamed(context, AppRouter.signup);
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
    Logger.info(
      'Navigating -> ${role.toUpperCase()} (user=$userName, email=${userEmail ?? 'N/A'})',
      tag: 'Login',
    );

    Widget destinationPage;

    if (role == 'driver') {
      destinationPage = const DriverPage();
    } else {
      destinationPage = const UserMapScreen();
    }

    // Replace current screen (so user can't go back to login)
    AppRouter.pushReplacement(context, destinationPage);
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
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Back button
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                      onPressed: () {
                        AppRouter.pop(context);
                      },
                    ),
                    const SizedBox(height: 10),

                    const Text(
                      "Log in",
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),

                    const Wrap(
                      children: [
                        Text(
                          "By Logging In, You Agree to Our ",
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
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _usernameController,
                      validator: validateUsername,
                      decoration: InputDecoration(
                        hintText: "Enter your Username",
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
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Colors.red),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Colors.red,
                            width: 2,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Password field
                    const Text(
                      "Password",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      validator: (value) =>
                          validatePassword(value, minLength: 3),
                      decoration: InputDecoration(
                        hintText: "Enter your Password",
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
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Colors.red),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Colors.red,
                            width: 2,
                          ),
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
          ),
          // Loading overlay
          if (_isLoading) const LoadingOverlay(),
        ],
      ),
    );
  }
}
