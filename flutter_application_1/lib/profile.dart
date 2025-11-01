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
  Map<String, dynamic>? _profileData;
  String _displayName = '';
  String _displayEmail = '';
  String _displayPhone = '+91 9876543210'; // Default fallback
  String _displayRole = 'User';
  int _completedRides = 0;

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
    print('========================');

    try {
      final response = await http.get(
        Uri.parse('http://localhost:8000/api/rides/user/profile/'),
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

        setState(() {
          _profileData = data;
          _displayName = data['username'] ?? widget.userName;
          _displayEmail = data['email'] ?? widget.userEmail;
          _displayPhone = data['phone_number'] ?? '+91 9876543210';
          _displayRole = (data['role'] ?? widget.userType)
              .toString()
              .capitalize();
          _completedRides = data['completed_rides'] ?? 0;
          _isLoading = false;
        });

        print('=== PROFILE UPDATED ===');
        print('Name: $_displayName');
        print('Email: $_displayEmail');
        print('Phone: $_displayPhone');
        print('Role: $_displayRole');
        print('Completed Rides: $_completedRides');
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
          : Column(
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
                          const SizedBox(width: 48), // Balance the back button
                        ],
                      ),
                      const SizedBox(height: 10),
                      const CircleAvatar(
                        radius: 45,
                        backgroundImage: AssetImage(
                          'assets/download16.jpeg',
                        ), // Using available asset
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
                      // Show completed rides if available
                      if (_completedRides > 0)
                        Text(
                          '$_completedRides Completed Rides',
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
                                    _displayPhone,
                                    style: TextStyle(
                                      color: Colors.cyan, // Updated color
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
                    ],
                  ),
                ),

                // 🔹 Bottom Section (My Wallet & Past Rides)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: Container(
                            width: double.infinity,
                            margin: const EdgeInsets.symmetric(vertical: 10),
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
                              child: Text(
                                "My Wallet",
                                style: TextStyle(
                                  color: Colors.cyan, // Updated color
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Container(
                            width: double.infinity,
                            margin: const EdgeInsets.symmetric(vertical: 10),
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
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Text(
                                    "Past Rides",
                                    style: TextStyle(
                                      color: Colors.cyan, // Updated color
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (_completedRides > 0)
                                    Text(
                                      '$_completedRides completed',
                                      style: const TextStyle(
                                        color: Colors.grey,
                                        fontSize: 14,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
