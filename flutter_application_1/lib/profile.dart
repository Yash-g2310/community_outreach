import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;

// Extension to capitalize strings
extension StringCapitalization on String {
  String capitalize() {
    if (isEmpty) return this;
    return this[0].toUpperCase() + substring(1).toLowerCase();
  }
}

void main() {
  runApp(const ProfileApp());
}

class ProfileApp extends StatelessWidget {
  const ProfileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'E-Rick Driver Profile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.cyan),
        useMaterial3: true,
      ),
      home: const ProfilePage(),
    );
  }
}

class ProfilePage extends StatefulWidget {
  final String userType;
  final String userName;
  final String userEmail;
  final String? accessToken; // JWT token for API calls

  const ProfilePage({
    super.key,
    this.userType = 'User',
    this.userName = 'E-Rick User',
    this.userEmail = 'user@email.com',
    this.accessToken,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _isLoading = true;
  bool _isUploading = false;

  // Dynamic profile fields
  String _displayName = '';
  String _displayEmail = '';
  String _displayPhone = '';
  String? _profilePicture;
  String _displayRole = 'User';
  String? _vehicleNumber; // Only for drivers

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();

    print('=== WIDGET INITIALIZATION ===');
    print('widget.userName: "${widget.userName}"');
    print('widget.userEmail: "${widget.userEmail}"');
    print('widget.userType: "${widget.userType}"');
    print('widget.accessToken available: ${widget.accessToken != null}');
    print('============================');

    _displayName = widget.userName;
    _displayEmail = widget.userEmail;
    _displayRole = widget.userType;

    // Fetch profile data if token is available
    if (widget.accessToken != null) {
      _fetchProfileData();
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Fetch user profile from Django API
  Future<void> _fetchProfileData() async {
    if (widget.accessToken == null) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    print('=== FETCHING PROFILE ===');
    print('Using access token for profile fetch');
    print('User Type: ${widget.userType}');
    print('========================');

    try {
      String apiEndpoint;
      // Determine which API endpoint to use based on user type
      if (widget.userType.toLowerCase() == 'driver') {
        apiEndpoint = 'http://localhost:8000/api/rides/driver/profile/';
      } else {
        apiEndpoint = 'http://localhost:8000/api/rides/user/profile/';
      }

      final response = await http.get(
        Uri.parse(apiEndpoint),
        headers: {
          'Authorization': 'Bearer ${widget.accessToken}',
          'Content-Type': 'application/json',
        },
      );

      print('=== PROFILE API RESPONSE ===');
      print('Status Code: ${response.statusCode}');
      print('Response Body: ${response.body}');
      print('============================');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        print('=== PROCESSING API RESPONSE ===');
        print('Full response data: $data');
        print('Data keys: ${data.keys.toList()}');

        setState(() {
          if (widget.userType.toLowerCase() == 'driver') {
            // Handle driver profile structure (nested user object)
            _handleDriverProfile(data);
          } else {
            // Handle user profile structure (flat structure)
            _handleUserProfile(data);
          }
          _isLoading = false;
        });

        print('=== PROFILE UPDATE COMPLETE ===');
        print('Name: $_displayName');
        print('Email: $_displayEmail');
        print('Phone: "$_displayPhone"');
        print('Role: $_displayRole');
        if (_vehicleNumber != null) print('Vehicle: $_vehicleNumber');
        print('===============================');
      } else {
        print('❌ Failed to fetch profile: ${response.statusCode}');
        print('Response: ${response.body}');
        setState(() {
          _isLoading = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Failed to load profile: HTTP ${response.statusCode}',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (error) {
      print('❌ Profile fetch error: $error');
      setState(() {
        _isLoading = false;
      });

      // Show error message to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Network error: ${error.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Handle driver profile API response structure
  void _handleDriverProfile(Map<String, dynamic> data) {
    print('=== PROCESSING DRIVER PROFILE ===');
    print('Raw API data: $data');
    print('Data type: ${data.runtimeType}');
    print('Data keys: ${data.keys.toList()}');

    // Driver profile has nested user object + driver-specific fields
    final userData = data['user'] as Map<String, dynamic>?;

    if (userData != null) {
      print('User data found: $userData');
      print('User data keys: ${userData.keys.toList()}');
      print(
        'Raw username: ${userData['username']} (${userData['username'].runtimeType})',
      );
      print(
        'Raw email: ${userData['email']} (${userData['email'].runtimeType})',
      );
      print(
        'Raw phone_number: ${userData['phone_number']} (${userData['phone_number'].runtimeType})',
      );
      print(
        'Raw profile_picture_url: ${userData['profile_picture_url']}',
      ); // Updated debug statement
      print('Raw role: ${userData['role']}');

      // Extract user information from nested object
      _displayName = userData['username']?.toString() ?? widget.userName;
      _displayEmail = userData['email']?.toString() ?? widget.userEmail;

      // Special handling for phone number
      final rawPhone = userData['phone_number'];
      print('🔍 Phone number debugging:');
      print('  Raw phone value: $rawPhone');
      print('  Raw phone type: ${rawPhone.runtimeType}');
      print('  Is null?: ${rawPhone == null}');
      print('  Is empty string?: ${rawPhone == ""}');
      print('  ToString result: "${rawPhone?.toString()}"');

      if (rawPhone == null || rawPhone.toString().trim().isEmpty) {
        _displayPhone = 'No phone number';
        print('  → Setting to "No phone number"');
      } else {
        _displayPhone = rawPhone.toString().trim();
        print('  → Setting to "$_displayPhone"');
      }

      _profilePicture =
          userData['profile_picture_url']; // Use profile_picture_url instead of profile_picture
      _displayRole = (userData['role']?.toString() ?? 'driver').capitalize();

      // Extract driver-specific information
      print(
        'Raw vehicle_number: ${data['vehicle_number']} (${data['vehicle_number'].runtimeType})',
      );
      _vehicleNumber = data['vehicle_number']?.toString();

      print('=== AFTER PROCESSING ===');
      print('Final _displayName: "$_displayName"');
      print('Final _displayEmail: "$_displayEmail"');
      print('Final _displayPhone: "$_displayPhone"');
      print('Final _displayRole: "$_displayRole"');
      print('Final _vehicleNumber: "$_vehicleNumber"');
      print('=======================');
    } else {
      print('❌ No user object found in driver profile');
      print('Available keys in response: ${data.keys.toList()}');
      // Check if data is flat instead of nested
      if (data.containsKey('username') || data.containsKey('email')) {
        print('🔍 Data appears to be flat structure, not nested!');
        print('Trying flat structure extraction...');
        _displayName = data['username']?.toString() ?? widget.userName;
        _displayEmail = data['email']?.toString() ?? widget.userEmail;

        // Special handling for phone number in flat structure
        final rawPhone = data['phone_number'];
        print('🔍 Flat structure phone debugging:');
        print('  Raw phone value: $rawPhone');
        print('  Raw phone type: ${rawPhone.runtimeType}');

        if (rawPhone == null || rawPhone.toString().trim().isEmpty) {
          _displayPhone = 'No phone number';
          print('  → Setting to "No phone number"');
        } else {
          _displayPhone = rawPhone.toString().trim();
          print('  → Setting to "$_displayPhone"');
        }

        _profilePicture =
            data['profile_picture_url']; // Use profile_picture_url instead of profile_picture
        _displayRole = (data['role']?.toString() ?? 'driver').capitalize();
        _vehicleNumber = data['vehicle_number']?.toString();

        print('Flat extraction results:');
        print('  Name: $_displayName');
        print('  Email: $_displayEmail');
        print('  Phone: $_displayPhone');
        print('  Vehicle: $_vehicleNumber');
      } else {
        // Fallback to widget defaults
        _displayName = widget.userName;
        _displayEmail = widget.userEmail;
        _displayPhone = 'No phone number';
        _displayRole = 'Driver';
        _vehicleNumber = null;
      }
    }
  }

  // Handle user profile API response structure
  void _handleUserProfile(Map<String, dynamic> data) {
    print('=== PROCESSING USER PROFILE ===');
    print('Raw API data: $data');
    print('Data type: ${data.runtimeType}');
    print('Data keys: ${data.keys.toList()}');
    print(
      'Raw username: ${data['username']} (${data['username'].runtimeType})',
    );
    print('Raw email: ${data['email']} (${data['email'].runtimeType})');
    print(
      'Raw phone_number: ${data['phone_number']} (${data['phone_number'].runtimeType})',
    );
    print(
      'Raw profile_picture_url: ${data['profile_picture_url']}',
    ); // Updated debug statement
    print('Raw role: ${data['role']}');

    // User profile has flat structure
    _displayName = data['username']?.toString() ?? widget.userName;
    _displayEmail = data['email']?.toString() ?? widget.userEmail;

    // Special handling for phone number
    final rawPhone = data['phone_number'];
    print('🔍 Phone number debugging:');
    print('  Raw phone value: $rawPhone');
    print('  Raw phone type: ${rawPhone.runtimeType}');
    print('  Is null?: ${rawPhone == null}');
    print('  Is empty string?: ${rawPhone == ""}');
    print('  ToString result: "${rawPhone?.toString()}"');

    if (rawPhone == null || rawPhone.toString().trim().isEmpty) {
      _displayPhone = 'No phone number';
      print('  → Setting to "No phone number"');
    } else {
      _displayPhone = rawPhone.toString().trim();
      print('  → Setting to "$_displayPhone"');
    }

    _profilePicture =
        data['profile_picture_url']; // Use profile_picture_url instead of profile_picture
    _displayRole = (data['role']?.toString() ?? 'user').capitalize();

    // Users don't have driver-specific fields
    _vehicleNumber = null;

    print('=== AFTER PROCESSING ===');
    print('Final _displayName: "$_displayName"');
    print('Final _displayEmail: "$_displayEmail"');
    print('Final _displayPhone: "$_displayPhone"');
    print('Final _displayRole: "$_displayRole"');
    print('=======================');
  }

  // Upload profile picture
  Future<void> _uploadProfilePicture() async {
    if (widget.accessToken == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please login to upload profile picture'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      // Pick image - handle web platform differently
      Uint8List? imageBytes;
      String fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';

      if (kIsWeb) {
        // For web, use XFile and read bytes directly
        final XFile? image = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 512,
          maxHeight: 512,
          imageQuality: 85,
        );

        if (image == null) return;
        imageBytes = await image.readAsBytes();
        fileName = image.name;
      } else {
        // For mobile platforms
        final XFile? image = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 512,
          maxHeight: 512,
          imageQuality: 85,
        );

        if (image == null) return;
        imageBytes = await image.readAsBytes();
      }

      setState(() {
        _isUploading = true;
      });

      // Prepare multipart request
      String apiEndpoint = 'http://localhost:8000/api/rides/user/profile/';

      var request = http.MultipartRequest('PATCH', Uri.parse(apiEndpoint));
      request.headers['Authorization'] = 'Bearer ${widget.accessToken}';

      // Add image file
      request.files.add(
        http.MultipartFile.fromBytes(
          'profile_picture',
          imageBytes,
          filename: fileName,
        ),
      );

      print('=== UPLOADING PROFILE PICTURE ===');
      print('Endpoint: $apiEndpoint');
      print('File size: ${imageBytes.length} bytes');
      print('Filename: $fileName');

      // Send request
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      print('Upload Status: ${response.statusCode}');
      print('Upload Response: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _profilePicture = data['profile_picture_url'];
          _isUploading = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Profile picture updated successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        setState(() {
          _isUploading = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Upload failed: ${response.statusCode}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (error) {
      print('❌ Upload error: $error');
      setState(() {
        _isUploading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload error: ${error.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                children: [
                  // 🔹 Top Section
                  Container(
                    padding: const EdgeInsets.only(top: 80, bottom: 30),
                    width: double.infinity,
                    decoration: const BoxDecoration(
                      color: Colors.cyan, // Changed to match E-Rick theme
                      borderRadius: BorderRadius.only(
                        bottomLeft: Radius.circular(30),
                        bottomRight: Radius.circular(30),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Back button
                        Row(
                          children: [
                            IconButton(
                              onPressed: () {
                                print('=== NAVIGATION ===');
                                print(
                                  'Going back from Profile to ${_displayRole == 'Driver' ? 'Driver Dashboard' : 'User Home Page'}',
                                );
                                print('==================');
                                Navigator.pop(context);
                              },
                              icon: const Icon(
                                Icons.arrow_back_ios_new,
                                color: Colors.white,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                _displayRole == 'Driver'
                                    ? 'Driver Profile'
                                    : 'User Profile',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(
                              width: 48,
                            ), // Balance the back button
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Profile Image - dynamic based on API response
                        Stack(
                          children: [
                            CircleAvatar(
                              radius: 45,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.3,
                              ),
                              child: _isUploading
                                  ? const CircularProgressIndicator(
                                      color: Colors.white,
                                    )
                                  : _profilePicture != null
                                  ? ClipOval(
                                      child: Image.network(
                                        _profilePicture!,
                                        width: 90,
                                        height: 90,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                              return const Icon(
                                                Icons.person,
                                                size: 50,
                                                color: Colors.white,
                                              );
                                            },
                                      ),
                                    )
                                  : const Icon(
                                      Icons.person,
                                      size: 50,
                                      color: Colors.white,
                                    ),
                            ),
                            // Edit button
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: GestureDetector(
                                onTap: _isUploading
                                    ? null
                                    : _uploadProfilePicture,
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.cyan,
                                      width: 2,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.camera_alt,
                                    size: 16,
                                    color: Colors.cyan,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _displayName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _displayRole,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 🔸 Middle Section (Phone + Email cards)
                  Padding(
                    padding: const EdgeInsets.all(
                      24.0,
                    ), // increased margin all around
                    child: Column(
                      children: [
                        // Phone Number Card
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 20),
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.phone_rounded,
                                color: Colors.cyan,
                                size: 28,
                              ), // Updated color
                              SizedBox(width: 15),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "Phone Number",
                                      style: TextStyle(
                                        color: Colors.black54,
                                        fontSize: 14,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      _displayPhone.isEmpty
                                          ? 'No phone number'
                                          : _displayPhone,
                                      style: TextStyle(
                                        color: _displayPhone.isEmpty
                                            ? Colors.grey
                                            : Colors.cyan, // Updated color
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Email Card
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.email_rounded,
                                color: Colors.cyan,
                                size: 28,
                              ), // Updated color
                              SizedBox(width: 15),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "E-mail",
                                      style: TextStyle(
                                        color: Colors.black54,
                                        fontSize: 14,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      _displayEmail,
                                      style: const TextStyle(
                                        color: Colors.cyan, // Updated color
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Vehicle Number Card (only for drivers)
                        if (_displayRole.toLowerCase() == 'driver' &&
                            _vehicleNumber != null)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(top: 20),
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.local_taxi,
                                  color: Colors.cyan,
                                  size: 28,
                                ),
                                const SizedBox(width: 15),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "Vehicle Number",
                                        style: TextStyle(
                                          color: Colors.black54,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _vehicleNumber!,
                                        style: const TextStyle(
                                          color: Colors.cyan,
                                          fontSize: 17,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20), // Add some bottom spacing
                ],
              ),
            ),
    );
  }
}
