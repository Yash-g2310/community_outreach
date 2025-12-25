import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/app_constants.dart';
import 'auth_service.dart';
import 'logger_service.dart';

/// Centralized API service for all HTTP operations
/// Provides automatic authentication, error handling, and logging
class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  final http.Client _client = http.Client();
  final AuthService _authService = AuthService();

  /// Perform a GET request
  /// [endpoint] - Full URL or endpoint path
  /// [requiresAuth] - Whether to include authentication header (default: true)
  /// [customHeaders] - Additional headers to include
  Future<http.Response> get(
    String endpoint, {
    bool requiresAuth = true,
    Map<String, String>? customHeaders,
  }) async {
    return _makeRequest(
      'GET',
      endpoint,
      requiresAuth: requiresAuth,
      customHeaders: customHeaders,
    );
  }

  /// Perform a POST request
  /// [endpoint] - Full URL or endpoint path
  /// [body] - Request body (will be JSON encoded)
  /// [requiresAuth] - Whether to include authentication header (default: true)
  /// [customHeaders] - Additional headers to include
  Future<http.Response> post(
    String endpoint, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
    Map<String, String>? customHeaders,
  }) async {
    return _makeRequest(
      'POST',
      endpoint,
      body: body,
      requiresAuth: requiresAuth,
      customHeaders: customHeaders,
    );
  }

  /// Perform a PUT request
  /// [endpoint] - Full URL or endpoint path
  /// [body] - Request body (will be JSON encoded)
  /// [requiresAuth] - Whether to include authentication header (default: true)
  /// [customHeaders] - Additional headers to include
  Future<http.Response> put(
    String endpoint, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
    Map<String, String>? customHeaders,
  }) async {
    return _makeRequest(
      'PUT',
      endpoint,
      body: body,
      requiresAuth: requiresAuth,
      customHeaders: customHeaders,
    );
  }

  /// Perform a PATCH request
  /// [endpoint] - Full URL or endpoint path
  /// [body] - Request body (will be JSON encoded)
  /// [requiresAuth] - Whether to include authentication header (default: true)
  /// [customHeaders] - Additional headers to include
  Future<http.Response> patch(
    String endpoint, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
    Map<String, String>? customHeaders,
  }) async {
    return _makeRequest(
      'PATCH',
      endpoint,
      body: body,
      requiresAuth: requiresAuth,
      customHeaders: customHeaders,
    );
  }

  /// Perform a DELETE request
  /// [endpoint] - Full URL or endpoint path
  /// [requiresAuth] - Whether to include authentication header (default: true)
  /// [customHeaders] - Additional headers to include
  Future<http.Response> delete(
    String endpoint, {
    bool requiresAuth = true,
    Map<String, String>? customHeaders,
  }) async {
    return _makeRequest(
      'DELETE',
      endpoint,
      requiresAuth: requiresAuth,
      customHeaders: customHeaders,
    );
  }

  /// Internal method to make HTTP requests
  Future<http.Response> _makeRequest(
    String method,
    String endpoint, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
    Map<String, String>? customHeaders,
  }) async {
    // Build full URL if endpoint is relative
    final uri = endpoint.startsWith('http')
        ? Uri.parse(endpoint)
        : Uri.parse(endpoint);

    // Prepare headers
    final headers = <String, String>{'Content-Type': 'application/json'};

    // Add authentication header if required
    if (requiresAuth) {
      final token = await _authService.getAccessToken();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }

    // Add custom headers
    if (customHeaders != null) {
      headers.addAll(customHeaders);
    }

    // Encode body if provided
    String? bodyString;
    if (body != null) {
      bodyString = json.encode(body);
    }

    // Log request
    Logger.network('$method $endpoint', tag: 'ApiService');
    if (body != null) {
      Logger.debug('Request body: $bodyString', tag: 'ApiService');
    }

    try {
      // Make the request with timeout
      http.Response response;
      switch (method.toUpperCase()) {
        case 'GET':
          response = await _client
              .get(uri, headers: headers)
              .timeout(NetworkConstants.requestTimeout);
          break;
        case 'POST':
          response = await _client
              .post(uri, headers: headers, body: bodyString)
              .timeout(NetworkConstants.requestTimeout);
          break;
        case 'PUT':
          response = await _client
              .put(uri, headers: headers, body: bodyString)
              .timeout(NetworkConstants.requestTimeout);
          break;
        case 'PATCH':
          response = await _client
              .patch(uri, headers: headers, body: bodyString)
              .timeout(NetworkConstants.requestTimeout);
          break;
        case 'DELETE':
          response = await _client
              .delete(uri, headers: headers)
              .timeout(NetworkConstants.requestTimeout);
          break;
        default:
          throw Exception('Unsupported HTTP method: $method');
      }

      // Log response
      Logger.network(
        'Response: ${response.statusCode} ${response.reasonPhrase}',
        tag: 'ApiService',
      );
      if (response.statusCode >= 400) {
        Logger.debug(
          'Error response body: ${response.body}',
          tag: 'ApiService',
        );
      }

      return response;
    } on http.ClientException catch (e) {
      Logger.error(
        'Network error: $method $endpoint',
        error: e,
        tag: 'ApiService',
      );
      rethrow;
    } on Exception catch (e) {
      Logger.error(
        'Request error: $method $endpoint',
        error: e,
        tag: 'ApiService',
      );
      rethrow;
    }
  }

  /// Dispose the HTTP client (call when app is closing)
  void dispose() {
    _client.close();
  }
}
