class Profile {
  final String username;
  final String email;
  final String phone;
  final String? profilePictureUrl;
  final String role;
  final String? vehicleNumber;

  Profile({
    required this.username,
    required this.email,
    required this.phone,
    this.profilePictureUrl,
    required this.role,
    this.vehicleNumber,
  });

  /// Normalize API response into a single model. The backend may return
  /// nested `user` object for drivers, or a flat structure for users.
  factory Profile.fromApi(Map<String, dynamic> data, {required bool isDriver}) {
    Map<String, dynamic> userMap = {};

    if (isDriver) {
      userMap = (data['user'] is Map<String, dynamic>)
          ? Map<String, dynamic>.from(data['user'])
          : Map<String, dynamic>.from(data);
    } else {
      userMap = Map<String, dynamic>.from(data);
    }

    String username = (userMap['username'] ?? '-')?.toString() ?? '-';
    String email = (userMap['email'] ?? '-')?.toString() ?? '-';
    String rawPhone = (userMap['phone_number'] ?? '')?.toString() ?? '';
    String phone = rawPhone.trim().isEmpty ? 'No phone number' : rawPhone.trim();
    String? picture = (userMap['profile_picture_url'] ?? userMap['profile_picture'])?.toString();
    String role = (userMap['role'] ?? (isDriver ? 'driver' : 'user'))?.toString() ?? (isDriver ? 'driver' : 'user');
    String? vehicle = data['vehicle_number']?.toString();

    return Profile(
      username: username,
      email: email,
      phone: phone,
      profilePictureUrl: picture,
      role: _capitalize(role),
      vehicleNumber: vehicle,
    );
  }

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1).toLowerCase();
  }
}
