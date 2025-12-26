import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../config/api_endpoints.dart';
import '../models/profile_model.dart';
import 'api_service.dart';
import 'auth_service.dart';

class ProfileService {
  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();

  Future<Profile> fetchProfile(String token, {required bool isDriver}) async {
    // Temporarily save token if not already saved (for cases like signup)
    final currentToken = await _authService.getAccessToken();
    if (currentToken != token) {
      await _authService.saveAuthData(accessToken: token);
    }

    final endpoint = isDriver
        ? DriverEndpoints.profile
        : UserProfileEndpoints.profile;

    final res = await _apiService.get(endpoint);

    if (res.statusCode != 200) {
      throw Exception('Failed to fetch profile: ${res.statusCode}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return Profile.fromApi(data, isDriver: isDriver);
  }

  Future<String?> uploadProfilePicture(
    String token,
    Uint8List bytes,
    String filename,
  ) async {
    // Temporarily save token if not already saved (for cases like signup)
    final currentToken = await _authService.getAccessToken();
    if (currentToken != token) {
      await _authService.saveAuthData(accessToken: token);
    }

    final endpoint = UserProfileEndpoints.profile;
    final file = http.MultipartFile.fromBytes(
      'profile_picture',
      bytes,
      filename: filename,
    );

    final res = await _apiService.postMultipart(
      endpoint,
      method: 'PATCH',
      files: [file],
    );

    if (res.statusCode != 200) {
      throw Exception('Upload failed: ${res.statusCode}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data['profile_picture_url']?.toString();
  }
}
