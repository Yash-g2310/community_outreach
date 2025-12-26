import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';

import '../../models/profile_model.dart';
import '../../services/profile_service.dart';
import '../../services/error_service.dart';
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
  final ImagePicker _picker = ImagePicker();
  final ErrorService _errorService = ErrorService();

  late final bool _isDriver;
  late Future<Profile> _profileFuture;
  bool _isUploading = false;

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

  Future<void> _uploadProfilePicture() async {
    if (widget.accessToken == null || widget.accessToken!.isEmpty) {
      if (mounted) {
        _errorService.showError(
          context,
          'Please login to upload profile picture',
        );
      }
      return;
    }

    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (image == null) return;
      final Uint8List bytes = await image.readAsBytes();
      final String filename = image.name.isNotEmpty
          ? image.name
          : 'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';

      setState(() => _isUploading = true);
      await _service.uploadProfilePicture(widget.accessToken!, bytes, filename);

      if (mounted) {
        _errorService.showSuccess(
          context,
          'Profile picture updated successfully!',
        );
      }

      setState(() {
        _profileFuture = _loadProfile();
        _isUploading = false;
      });
    } catch (e) {
      setState(() => _isUploading = false);
      if (mounted) {
        _errorService.showError(context, 'Upload error: ${e.toString()}');
      }
    }
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
          Stack(
            children: [
              CircleAvatar(
                radius: 45,
                backgroundColor: Colors.white.withValues(alpha: 0.3),
                child: _isUploading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : (p.profilePictureUrl != null
                          ? ClipOval(
                              child: Image.network(
                                p.profilePictureUrl!,
                                width: 90,
                                height: 90,
                                fit: BoxFit.cover,
                              ),
                            )
                          : const Icon(
                              Icons.person,
                              size: 50,
                              color: Colors.white,
                            )),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: GestureDetector(
                  onTap: _isUploading ? null : _uploadProfilePicture,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.cyan, width: 2),
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
