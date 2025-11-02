import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

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

  // Dynamic profile fields
  String _displayName = '';
  String _displayEmail = '';
  String _displayPhone = '';
  String? _profilePicture;
  String _displayRole = 'User';
  String? _vehicleNumber; // Only for drivers

  @override
  void initState() {
    super.initState();
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

        print('=== DETAILED API DATA ANALYSIS ===');
        print('Full response data: $data');
        print('Data type: ${data.runtimeType}');
        print('Data keys: ${data.keys.toList()}');

        setState(() {
          // Handle driver profile structure
          if (widget.userType.toLowerCase() == 'driver' &&
              data.containsKey('user')) {
            final userData = data['user'];
            print('=== DRIVER PROFILE STRUCTURE ===');
            print('User data: $userData');
            print('User data keys: ${userData.keys.toList()}');
            print('Phone field in userData: "${userData['phone_number']}"');
            print('Phone field type: ${userData['phone_number'].runtimeType}');
            print('Phone field is null: ${userData['phone_number'] == null}');

            _displayName = userData['username'] ?? widget.userName;
            _displayEmail = userData['email'] ?? widget.userEmail;

            // More explicit phone number handling
            final phoneFromApi = userData['phone_number'];
            print('Raw phone from API: $phoneFromApi');
            if (phoneFromApi != null) {
              _displayPhone = phoneFromApi.toString();
              print('Phone after toString(): "$_displayPhone"');
            } else {
              _displayPhone = 'No phone number available';
              print('Phone was null, using fallback');
            }

            _profilePicture = userData['profile_picture'];
            _displayRole = (userData['role'] ?? widget.userType)
                .toString()
                .capitalize();
            _vehicleNumber = data['vehicle_number']; // Driver-specific field
          } else {
            // Handle regular user profile structure
            print('=== USER PROFILE STRUCTURE ===');
            print('Direct data phone field: ${data['phone_number']}');
            print('Phone field type: ${data['phone_number'].runtimeType}');

            _displayName = data['username'] ?? widget.userName;
            _displayEmail = data['email'] ?? widget.userEmail;
            _displayPhone =
                data['phone_number']?.toString() ?? 'No phone number';
            _profilePicture = data['profile_picture'];
            _displayRole = (data['role'] ?? widget.userType)
                .toString()
                .capitalize();
          }

          _isLoading = false;
        });

        print('=== PROFILE UPDATED ===');
        print('Name: $_displayName');
        print('Email: $_displayEmail');
        print('Phone: "$_displayPhone" (Length: ${_displayPhone.length})');
        print('Phone isEmpty: ${_displayPhone.isEmpty}');
        print('Phone == "": ${_displayPhone == ""}');
        print('Role: $_displayRole');
        print('Profile Picture: $_profilePicture');
        if (_vehicleNumber != null) print('Vehicle Number: $_vehicleNumber');
        print('======================');
      } else {
        print('❌ Failed to fetch profile: ${response.statusCode}');
        setState(() {
          _isLoading = false;
        });
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
            content: Text('Failed to load profile: ${error.toString()}'),
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
                        CircleAvatar(
                          radius: 45,
                          backgroundColor: Colors.white.withOpacity(0.3),
                          child: _profilePicture != null
                              ? ClipOval(
                                  child: Image.network(
                                    _profilePicture!,
                                    width: 90,
                                    height: 90,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
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
                                color: Colors.black.withOpacity(0.08),
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
                                color: Colors.black.withOpacity(0.08),
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
                                  color: Colors.black.withOpacity(0.08),
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

                  // 🔹 Bottom Section (Placeholder for future features)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: Container(
                      width: double.infinity,
                      height: 200, // Fixed height instead of Expanded
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.withOpacity(0.2),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.account_circle_outlined,
                              size: 64,
                              color: Colors.cyan,
                            ),
                            SizedBox(height: 16),
                            Text(
                              "Profile",
                              style: TextStyle(
                                color: Colors.cyan,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              "Complete profile information",
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20), // Add some bottom spacing
                ],
              ),
            ),
    );
  }
}
