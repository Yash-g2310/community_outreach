import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config/api_endpoints.dart';
import 'websocket_service.dart';
import 'logger_service.dart';

/// Authentication service for managing user authentication state
class AuthService {
  static const String _keyAccessToken = 'auth_access_token';
  static const String _keyRefreshToken = 'auth_refresh_token';
  static const String _keyUserData = 'auth_user_data';
  static const String _keyUserRole = 'auth_user_role';

  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  SharedPreferences? _prefs;

  /// Initialize the service by loading SharedPreferences
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Check if user is currently authenticated
  Future<bool> isAuthenticated() async {
    await init();
    final token = _prefs?.getString(_keyAccessToken);
    return token != null && token.isNotEmpty;
  }

  /// Get the current access token
  Future<String?> getAccessToken() async {
    await init();
    return _prefs?.getString(_keyAccessToken);
  }

  /// Get the current refresh token
  Future<String?> getRefreshToken() async {
    await init();
    return _prefs?.getString(_keyRefreshToken);
  }

  /// Get the current primary role (driver/rider).
  Future<String?> getUserRole() async {
    await init();
    return _normalizeRole(_prefs?.getString(_keyUserRole));
  }

  /// Get the current user data
  Future<Map<String, dynamic>?> getUserData() async {
    await init();
    final userDataJson = _prefs?.getString(_keyUserData);
    if (userDataJson == null) return null;
    try {
      return Map<String, dynamic>.from(json.decode(userDataJson));
    } catch (e) {
      return null;
    }
  }

  /// Save authentication tokens and user data
  Future<void> saveAuthData({
    required String accessToken,
    String? refreshToken,
    Map<String, dynamic>? userData,
  }) async {
    await init();
    await _prefs?.setString(_keyAccessToken, accessToken);
    if (refreshToken != null) {
      await _prefs?.setString(_keyRefreshToken, refreshToken);
    }
    if (userData != null) {
      final normalizedUserData = Map<String, dynamic>.from(userData);
      final role = _primaryRole(normalizedUserData);
      normalizedUserData['role'] = role;
      await _prefs?.setString(_keyUserData, json.encode(normalizedUserData));
      await _prefs?.setString(_keyUserRole, role);
    }
  }

  /// Clear all authentication data (logout)
  Future<void> clearAuthData() async {
    await init();
    final accessToken = await getAccessToken();
    if (accessToken != null && accessToken.isNotEmpty) {
      try {
        await http
            .post(
              Uri.parse(AuthEndpoints.logout),
              headers: {'Authorization': 'Bearer $accessToken'},
            )
            .timeout(const Duration(seconds: 10));
      } catch (error) {
        // Local logout must still complete when the server is unreachable.
        Logger.warning('Unable to revoke the server session during logout: $error', tag: 'AuthService');
      }
    }
    await _prefs?.remove(_keyAccessToken);
    await _prefs?.remove(_keyRefreshToken);
    await _prefs?.remove(_keyUserData);
    await _prefs?.remove(_keyUserRole);

    // Disconnect all WebSocket connections on logout
    try {
      final wsService = WebSocketService();
      wsService.disconnectAll();
    } catch (e) {
      Logger.error(
        'Error disconnecting WebSockets on logout',
        error: e,
        tag: 'AuthService',
      );
    }
  }

  /// Refresh access token using refresh token
  /// Returns true if refresh was successful, false otherwise
  Future<bool> refreshAccessToken() async {
    await init();
    final refreshToken = await getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      Logger.warning(
        'Cannot refresh token: no refresh token available',
        tag: 'AuthService',
      );
      return false;
    }

    try {
      final response = await http
          .post(
            Uri.parse(AuthEndpoints.refresh),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'refresh': refreshToken}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final tokenPayload = data['tokens'] is Map
            ? Map<String, dynamic>.from(data['tokens'] as Map)
            : data;
        final newAccessToken = tokenPayload['access']?.toString();
        final newRefreshToken = tokenPayload['refresh']?.toString();
        if (newAccessToken != null && newAccessToken.isNotEmpty) {
          await _prefs?.setString(_keyAccessToken, newAccessToken);
          if (newRefreshToken != null && newRefreshToken.isNotEmpty) {
            await _prefs?.setString(_keyRefreshToken, newRefreshToken);
          }
          await WebSocketService().reconnectWithAccessToken(newAccessToken);
          Logger.info(
            'Access token refreshed successfully',
            tag: 'AuthService',
          );
          return true;
        }
      }
      Logger.warning(
        'Token refresh failed: ${response.statusCode}',
        tag: 'AuthService',
      );
      return false;
    } catch (e) {
      Logger.error('Error refreshing token', error: e, tag: 'AuthService');
      return false;
    }
  }

  /// Get authentication state summary
  Future<AuthState> getAuthState() async {
    await init();
    final isAuth = await isAuthenticated();
    if (!isAuth) {
      return AuthState.unauthenticated();
    }

    final role = await getUserRole();
    final userData = await getUserData();
    final accessToken = await getAccessToken();

    return AuthState.authenticated(
      accessToken: accessToken!,
      refreshToken: await getRefreshToken(),
      role: role ?? 'rider',
      userData: userData ?? {},
    );
  }

  String _primaryRole(Map<String, dynamic> userData) {
    final roles = userData['roles'];
    if (roles is List && roles.map((role) => role.toString()).contains('driver')) {
      return 'driver';
    }
    return _normalizeRole(userData['role']?.toString()) ?? 'rider';
  }

  String? _normalizeRole(String? role) {
    if (role == null || role.isEmpty) return role;
    return role == 'user' ? 'rider' : role;
  }
}

/// Represents the current authentication state
class AuthState {
  final bool isAuthenticated;
  final String? accessToken;
  final String? refreshToken;
  final String? role;
  final Map<String, dynamic>? userData;

  AuthState({
    required this.isAuthenticated,
    this.accessToken,
    this.refreshToken,
    this.role,
    this.userData,
  });

  factory AuthState.unauthenticated() {
    return AuthState(isAuthenticated: false);
  }

  factory AuthState.authenticated({
    required String accessToken,
    String? refreshToken,
    required String role,
    Map<String, dynamic>? userData,
  }) {
    return AuthState(
      isAuthenticated: true,
      accessToken: accessToken,
      refreshToken: refreshToken,
      role: role,
      userData: userData,
    );
  }

  bool get isDriver => role == 'driver';
  bool get isRider => role == 'rider' || role == 'user' || role == null;
  bool get isUser => isRider;
}
