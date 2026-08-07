import 'dart:convert';
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

    final res = await _apiService.get(AuthEndpoints.profile);

    if (res.statusCode != 200) {
      throw Exception('Failed to fetch profile: ${res.statusCode}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return Profile.fromApi(data, isDriver: isDriver);
  }
}
