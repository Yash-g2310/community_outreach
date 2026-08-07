import 'package:flutter/material.dart';

import '../../models/profile_model.dart';
import '../../services/profile_service.dart';
import '../../router/app_router.dart';

/// Clean ProfilePage implementation. Use this instead of the legacy/merged `profile.dart`.
class ProfilePage extends StatefulWidget {
  final String userType;
  final String userName;
  final String userEmail;
  final String? accessToken;

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
  final ProfileService _service = ProfileService();

  late final bool _isDriver;
  late Future<Profile> _profileFuture;

  @override
  void initState() {
    super.initState();
    _isDriver = widget.userType.toLowerCase() == 'driver';
    _profileFuture = _loadProfile();
  }

  Future<Profile> _loadProfile() async {
    if (widget.accessToken != null && widget.accessToken!.isNotEmpty) {
      return _service.fetchProfile(widget.accessToken!, isDriver: _isDriver);
    }
    return Profile(
      username: widget.userName,
      email: widget.userEmail,
      phone: 'No phone number',
      profilePictureUrl: null,
      role: _isDriver ? 'Driver' : 'User',
      vehicleNumber: null,
    );
  }

  Widget _buildHeader(Profile p) {
    return Container(
      padding: const EdgeInsets.only(top: 80, bottom: 30),
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.cyan,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(30),
          bottomRight: Radius.circular(30),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => AppRouter.pop(context),
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
              ),
              Expanded(
                child: Text(
                  p.role.toLowerCase() == 'driver'
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
              const SizedBox(width: 48),
            ],
          ),
          const SizedBox(height: 10),
          CircleAvatar(
            radius: 45,
            backgroundColor: Colors.white.withValues(alpha: 0.3),
            child: p.profilePictureUrl != null
                ? ClipOval(
                    child: Image.network(
                      p.profilePictureUrl!,
                      width: 90,
                      height: 90,
                      fit: BoxFit.cover,
                    ),
                  )
                : const Icon(Icons.person, size: 50, color: Colors.white),
          ),
          const SizedBox(height: 10),
          Text(
            p.username,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            p.role,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _infoCard(String title, String content, {IconData? icon}) {
    return Container(
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
          Icon(icon ?? Icons.info, color: Colors.cyan, size: 28),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                Text(
                  content,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: FutureBuilder<Profile>(
        future: _profileFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final profile = snap.data!;
          return SingleChildScrollView(
            child: Column(
              children: [
                _buildHeader(profile),
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    children: [
                      _infoCard(
                        'Phone Number',
                        profile.phone,
                        icon: Icons.phone_rounded,
                      ),
                      _infoCard(
                        'E-mail',
                        profile.email,
                        icon: Icons.email_rounded,
                      ),
                      if (_isDriver &&
                          (profile.vehicleNumber != null &&
                              profile.vehicleNumber!.isNotEmpty))
                        _infoCard(
                          'Vehicle',
                          profile.vehicleNumber ?? '-',
                          icon: Icons.local_taxi,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          );
        },
      ),
    );
  }
}
