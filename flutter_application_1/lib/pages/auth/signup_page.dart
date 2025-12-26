import 'package:flutter/material.dart';
import '../../config/api_endpoints.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';
import '../../utils/validators.dart';
import '../../router/app_router.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  bool _isLoading = false;
  String _selectedRole = 'user';
  Uint8List? _profileImageBytes; // For web compatibility
  String? _profileImagePath; // For storing image path info

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

  // Pick profile image - Web compatible
  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 500,
      maxHeight: 500,
      imageQuality: 80,
    );

    if (image != null) {
      // Read image as bytes (works on web and mobile)
      final bytes = await image.readAsBytes();
      setState(() {
        _profileImageBytes = bytes;
        _profileImagePath = image.name;
      });
    }
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

  // Signup with Django API
  Future<void> _signupWithServer() async {
    final navigator = Navigator.of(context);

    Logger.info('=== SIGNUP REQUEST ===', tag: 'Signup');
    Logger.debug('Username: ${_usernameController.text}', tag: 'Signup');
    Logger.debug('Email: ${_emailController.text}', tag: 'Signup');
    Logger.debug('Role: $_selectedRole', tag: 'Signup');
    Logger.debug('Phone: ${_phoneController.text}', tag: 'Signup');
    if (_selectedRole == 'driver') {
      Logger.debug('Vehicle Number: ${_erickNoController.text}', tag: 'Signup');
    }
    Logger.debug(
      'Profile Image: ${_profileImageBytes != null ? 'Selected' : 'None'}',
      tag: 'Signup',
    );
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

      final response = await http.post(
        Uri.parse(AuthEndpoints.register),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestData),
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
        final tokens = responseData['tokens'];
        final accessToken = tokens['access'];

        Logger.info('=== SIGNUP SUCCESS ===', tag: 'Signup');
        Logger.debug('User Name: $userName', tag: 'Signup');
        Logger.debug('User Role: $userRole', tag: 'Signup');
        Logger.debug('User ID: ${userData['id']}', tag: 'Signup');
        Logger.debug(
          'Access Token: ${accessToken.substring(0, 20)}...',
          tag: 'Signup',
        );

        // Upload profile picture if selected
        if (_profileImageBytes != null) {
          Logger.info('=== UPLOADING PROFILE PICTURE ===', tag: 'Signup');
          await _uploadProfilePicture(accessToken);
        }

        // Show success message
        if (!mounted) return;

        _errorService.showSuccess(
          context,
          'Welcome $userName! Account created successfully. Please log in.',
        );

        // Navigate back to login page
        navigator.pop();
      } else if (response.statusCode == 400) {
        // Handle validation errors
        final responseData = jsonDecode(response.body);

        Logger.warning('=== VALIDATION ERRORS ===', tag: 'Signup');
        Logger.debug('Errors: $responseData', tag: 'Signup');

        // Extract and show specific error messages
        String errorMessage = 'Signup failed:\n';

        if (responseData is Map<String, dynamic>) {
          responseData.forEach((field, errors) {
            if (errors is List) {
              errorMessage +=
                  '• ${field.replaceAll('_', ' ')}: ${errors.join(', ')}\n';
            } else {
              errorMessage += '• ${field.replaceAll('_', ' ')}: $errors\n';
            }
          });
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

  // Upload profile picture after successful registration
  Future<void> _uploadProfilePicture(String accessToken) async {
    if (_profileImageBytes == null) return;

    try {
      var request = http.MultipartRequest(
        'PATCH',
        Uri.parse(UserProfileEndpoints.profile),
      );

      request.headers['Authorization'] = 'Bearer $accessToken';

      // Add image file
      request.files.add(
        http.MultipartFile.fromBytes(
          'profile_picture',
          _profileImageBytes!,
          filename: _profileImagePath ?? 'profile.jpg',
        ),
      );

      Logger.info('Uploading profile picture...', tag: 'Signup');
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      Logger.debug('Upload Status: ${response.statusCode}', tag: 'Signup');
      Logger.debug('Upload Response: ${response.body}', tag: 'Signup');

      if (response.statusCode == 200) {
        Logger.info('Profile picture uploaded successfully', tag: 'Signup');
      } else {
        Logger.warning(
          'Profile picture upload failed: ${response.statusCode}',
          tag: 'Signup',
        );
      }
    } catch (error) {
      Logger.error('Profile picture upload error', error: error, tag: 'Signup');
      // Don't throw - registration was successful, just picture upload failed
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
                          label: const Text('User'),
                          selected: _selectedRole == 'user',
                          onSelected: (selected) {
                            if (!selected) return;
                            setState(() {
                              _selectedRole = 'user';
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

                    // Profile picture upload
                    const Text(
                      "Profile Picture (Optional)",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        height: 120,
                        width: 120,
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(60),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: _profileImageBytes != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(60),
                                child: Image.memory(
                                  _profileImageBytes!,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : const Icon(
                                Icons.add_a_photo,
                                size: 40,
                                color: Colors.grey,
                              ),
                      ),
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
                          validatePassword(value, minLength: 3),
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
