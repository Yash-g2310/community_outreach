import 'package:flutter/material.dart';
import '../../config/api_endpoints.dart';
import 'dart:convert';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../utils/validators.dart';
import '../../router/app_router.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  bool _isLoading = false;
  String _selectedRole = 'rider';

  // Form key for validation
  final _formKey = GlobalKey<FormState>();

  // Text controllers for form fields
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _erickNoController = TextEditingController();

  final ErrorService _errorService = ErrorService();
  final ApiService _apiService = ApiService();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _erickNoController.dispose();
    super.dispose();
  }

  // Handle signup
  void _handleSignup() async {
    // Validate all required fields using form validators
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Additional validation for driver role
    if (_selectedRole == 'driver' && _erickNoController.text.trim().isEmpty) {
      _errorService.showError(context, 'E-Rick number is required for drivers');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      await _signupWithServer();
    } catch (error) {
      Logger.error('Signup error', error: error, tag: 'Signup');
      _errorService.handleError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Signup with the FastAPI account endpoint.
  Future<void> _signupWithServer() async {
    Logger.info('=== SIGNUP REQUEST ===', tag: 'Signup');
    Logger.debug('Username: ${_usernameController.text}', tag: 'Signup');
    Logger.debug('Email: ${_emailController.text}', tag: 'Signup');
    Logger.debug('Role: $_selectedRole', tag: 'Signup');
    Logger.debug('Phone: ${_phoneController.text}', tag: 'Signup');
    if (_selectedRole == 'driver') {
      Logger.debug('Vehicle Number: ${_erickNoController.text}', tag: 'Signup');
    }
    Logger.debug('API Endpoint: ${AuthEndpoints.register}', tag: 'Signup');

    try {
      // Prepare request data
      Map<String, dynamic> requestData = {
        'username': _usernameController.text.trim(),
        'email': _emailController.text.trim(),
        'password': _passwordController.text.trim(),
        'role': _selectedRole,
        'phone_number': _phoneController.text.trim(),
      };

      // Add vehicle number for drivers
      if (_selectedRole == 'driver') {
        requestData['vehicle_number'] = _erickNoController.text.trim();
      }

      final response = await _apiService.post(
        AuthEndpoints.register,
        body: requestData,
        requiresAuth: false,
      );

      Logger.network('=== API RESPONSE ===', tag: 'Signup');
      Logger.debug('Status Code: ${response.statusCode}', tag: 'Signup');
      Logger.debug('Response Body: ${response.body}', tag: 'Signup');

      if (response.statusCode == 201) {
        final responseData = jsonDecode(response.body);

        // Extract user data from API response
        final userData = responseData['user'];
        final userName = userData['username'];
        final userRole = userData['role'];
        final tokens = Map<String, dynamic>.from(responseData['tokens'] ?? {});
        final accessToken = tokens['access']?.toString();
        final refreshToken = tokens['refresh']?.toString();
        if (accessToken == null || accessToken.isEmpty) {
          throw Exception('Registration response missing access token');
        }

        Logger.info('=== SIGNUP SUCCESS ===', tag: 'Signup');
        Logger.debug('User Name: $userName', tag: 'Signup');
        Logger.debug('User Role: $userRole', tag: 'Signup');
        Logger.debug('User ID: ${userData['id']}', tag: 'Signup');
        Logger.debug(
          'Access Token: ${accessToken.length > 20 ? '${accessToken.substring(0, 20)}...' : accessToken}',
          tag: 'Signup',
        );

        await AuthService().saveAuthData(
          accessToken: accessToken,
          refreshToken: refreshToken,
          userData: Map<String, dynamic>.from(userData ?? {}),
        );

        // Show success message
        if (!mounted) return;

        _errorService.showSuccess(
          context,
          'Welcome $userName! Account created successfully.',
        );

        AppRouter.pushReplacementNamed(
          context,
          userRole == 'driver' ? AppRouter.driverHome : AppRouter.userHome,
        );
      } else if (response.statusCode == 400 || response.statusCode == 422) {
        // Handle validation errors
        final responseData = jsonDecode(response.body);

        Logger.warning('=== VALIDATION ERRORS ===', tag: 'Signup');
        Logger.debug('Errors: $responseData', tag: 'Signup');

        // Extract and show specific error messages
        String errorMessage = 'Signup failed:\n';

        if (responseData is Map<String, dynamic>) {
          final detail = responseData['detail'];
          if (detail is List) {
            for (final error in detail) {
              errorMessage += 'Invalid input: ${error is Map ? error['msg'] ?? 'Unknown error' : error}\n';
            }
          } else {
            responseData.forEach((field, errors) {
            if (errors is List) {
              errorMessage +=
                  '• ${field.replaceAll('_', ' ')}: ${errors.join(', ')}\n';
            } else {
              errorMessage += '• ${field.replaceAll('_', ' ')}: $errors\n';
            }
            });
          }
        } else {
          errorMessage += responseData.toString();
        }

        throw Exception(errorMessage.trim());
      } else {
        // Use ErrorService to handle HTTP response errors
        _errorService.handleError(context, null, response: response);
        return;
      }
    } catch (error) {
      Logger.error('=== API ERROR ===', error: error, tag: 'Signup');
      Logger.debug('Error Type: ${error.runtimeType}', tag: 'Signup');
      Logger.debug('Error Message: $error', tag: 'Signup');

      // Re-throw to be handled by caller
      rethrow;
    }
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
                      onPressed: () => AppRouter.pop(context),
                    ),
                    const SizedBox(height: 10),

                    const Text(
                      "Create Account",
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),

                    const Text(
                      "Join E-Rick Connect today",
                      style: TextStyle(fontSize: 16, color: Colors.black54),
                    ),
                    const SizedBox(height: 30),

                    // Role selection
                    const Text(
                      "Role",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      children: [
                        ChoiceChip(
                          label: const Text('Rider'),
                          selected: _selectedRole == 'rider',
                          onSelected: (selected) {
                            if (!selected) return;
                            setState(() {
                              _selectedRole = 'rider';
                            });
                          },
                        ),
                        ChoiceChip(
                          label: const Text('Driver'),
                          selected: _selectedRole == 'driver',
                          onSelected: (selected) {
                            if (!selected) return;
                            setState(() {
                              _selectedRole = 'driver';
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Username field
                    _buildTextField(
                      controller: _usernameController,
                      label: "Username",
                      hint: "Enter your username",
                      validator: validateUsername,
                    ),

                    // Email field
                    _buildTextField(
                      controller: _emailController,
                      label: "Email",
                      hint: "Enter your email",
                      keyboardType: TextInputType.emailAddress,
                      validator: validateEmail,
                    ),

                    // Phone field
                    _buildTextField(
                      controller: _phoneController,
                      label: "Phone Number",
                      hint: "Enter your phone number",
                      keyboardType: TextInputType.phone,
                      validator: validatePhoneNumber,
                    ),

                    // E-Rick number field (only for drivers)
                    if (_selectedRole == 'driver')
                      _buildTextField(
                        controller: _erickNoController,
                        label: "E-Rick Number",
                        hint: "Enter your E-Rick number",
                        validator: (value) =>
                            validateRequired(value, fieldName: 'E-Rick number'),
                      ),

                    // Password field
                    _buildTextField(
                      controller: _passwordController,
                      label: "Password",
                      hint: "Enter your password",
                      obscureText: true,
                      validator: (value) =>
                          validatePassword(value, minLength: 8),
                    ),

                    // Confirm password field
                    _buildTextField(
                      controller: _confirmPasswordController,
                      label: "Confirm Password",
                      hint: "Confirm your password",
                      obscureText: true,
                      validator: (value) => validatePasswordConfirmation(
                        value,
                        _passwordController.text,
                      ),
                    ),

                    const SizedBox(height: 30),

                    // Signup button
                    SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleSignup,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF7A00),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                        child: const Text(
                          "Create Account",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Login link
                    Center(
                      child: TextButton(
                        onPressed: () => AppRouter.pop(context),
                        child: const Text(
                          "Already have an account? Log in",
                          style: TextStyle(
                            color: Color(0xFFFF7A00),
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Loading overlay
          if (_isLoading)
            Container(
              color: Colors.black54,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType? keyboardType,
    bool obscureText = false,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscureText,
          validator: validator,
          decoration: InputDecoration(
            hintText: hint,
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
              borderSide: const BorderSide(color: Colors.red, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
