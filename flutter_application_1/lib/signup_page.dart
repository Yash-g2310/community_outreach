import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';

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

  // Text controllers for form fields
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _erickNoController = TextEditingController();

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
    // Validate all required fields
    if (!_validateForm()) return;

    setState(() {
      _isLoading = true;
    });

    final messenger = ScaffoldMessenger.of(context);

    try {
      await _signupWithServer();
    } catch (error) {
      print('Signup error: $error');
      messenger.showSnackBar(
        SnackBar(
          content: Text('Signup failed: ${error.toString()}'),
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

  // Validate form fields
  bool _validateForm() {
    if (_usernameController.text.trim().isEmpty) {
      _showError('Username is required');
      return false;
    }
    if (_passwordController.text.trim().isEmpty) {
      _showError('Password is required');
      return false;
    }
    if (_passwordController.text != _confirmPasswordController.text) {
      _showError('Passwords do not match');
      return false;
    }
    if (_emailController.text.trim().isEmpty) {
      _showError('Email is required');
      return false;
    }
    if (_phoneController.text.trim().isEmpty) {
      _showError('Phone number is required');
      return false;
    }
    if (_selectedRole == 'driver' && _erickNoController.text.trim().isEmpty) {
      _showError('E-Rick number is required for drivers');
      return false;
    }
    return true;
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  // Signup with Django API
  Future<void> _signupWithServer() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    print('=== SIGNUP REQUEST ===');
    print('Username: ${_usernameController.text}');
    print('Email: ${_emailController.text}');
    print('Role: $_selectedRole');
    print('Phone: ${_phoneController.text}');
    if (_selectedRole == 'driver') {
      print('Vehicle Number: ${_erickNoController.text}');
    }
    print('Profile Image: ${_profileImageBytes != null ? 'Selected' : 'None'}');
    print('API Endpoint: http://localhost:8000/api/auth/register/');
    print('=====================');

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
        Uri.parse('http://localhost:8000/api/auth/register/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestData),
      );

      print('=== API RESPONSE ===');
      print('Status Code: ${response.statusCode}');
      print('Response Body: ${response.body}');
      print('===================');

      if (response.statusCode == 201) {
        final responseData = jsonDecode(response.body);

        // Extract user data from API response
        final userData = responseData['user'];
        final userName = userData['username'];
        final userRole = userData['role'];
        final tokens = responseData['tokens'];
        final accessToken = tokens['access'];

        print('=== SIGNUP SUCCESS ===');
        print('User Name: $userName');
        print('User Role: $userRole');
        print('User ID: ${userData['id']}');
        print('Access Token: ${accessToken.substring(0, 20)}...');
        print('======================');

        // Upload profile picture if selected
        if (_profileImageBytes != null) {
          print('=== UPLOADING PROFILE PICTURE ===');
          await _uploadProfilePicture(accessToken);
        }

        // Show success message
        if (!mounted) return;

        // Show success message
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Welcome $userName! Account created successfully. Please log in.',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );

        // Navigate back to login page
        navigator.pop();
      } else if (response.statusCode == 400) {
        // Handle validation errors
        final responseData = jsonDecode(response.body);

        print('=== VALIDATION ERRORS ===');
        print('Errors: $responseData');
        print('========================');

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
        // Handle other errors
        final responseData = jsonDecode(response.body);
        final errorMessage = responseData['error'] ?? 'Signup failed';

        print('=== SIGNUP FAILED ===');
        print('Error: $errorMessage');
        print('====================');

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

  // Upload profile picture after successful registration
  Future<void> _uploadProfilePicture(String accessToken) async {
    if (_profileImageBytes == null) return;

    try {
      var request = http.MultipartRequest(
        'PATCH',
        Uri.parse('http://localhost:8000/api/rides/user/profile/'),
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

      print('Uploading profile picture...');
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      print('Upload Status: ${response.statusCode}');
      print('Upload Response: ${response.body}');

      if (response.statusCode == 200) {
        print('✅ Profile picture uploaded successfully');
      } else {
        print('⚠️ Profile picture upload failed: ${response.statusCode}');
      }
    } catch (error) {
      print('❌ Profile picture upload error: $error');
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Back button
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(height: 10),

                  const Text(
                    "Create Account",
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
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
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
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
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
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
                  ),

                  // Email field
                  _buildTextField(
                    controller: _emailController,
                    label: "Email",
                    hint: "Enter your email",
                    keyboardType: TextInputType.emailAddress,
                  ),

                  // Phone field
                  _buildTextField(
                    controller: _phoneController,
                    label: "Phone Number",
                    hint: "Enter your phone number",
                    keyboardType: TextInputType.phone,
                  ),

                  // E-Rick number field (only for drivers)
                  if (_selectedRole == 'driver')
                    _buildTextField(
                      controller: _erickNoController,
                      label: "E-Rick Number",
                      hint: "Enter your E-Rick number",
                    ),

                  // Password field
                  _buildTextField(
                    controller: _passwordController,
                    label: "Password",
                    hint: "Enter your password",
                    obscureText: true,
                  ),

                  // Confirm password field
                  _buildTextField(
                    controller: _confirmPasswordController,
                    label: "Confirm Password",
                    hint: "Confirm your password",
                    obscureText: true,
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
                      onPressed: () => Navigator.pop(context),
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
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscureText,
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
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
