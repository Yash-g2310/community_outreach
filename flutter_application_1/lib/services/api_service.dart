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

  /// Perform a multipart POST/PATCH request (for file uploads)
  /// [endpoint] - Full URL or endpoint path
  /// [method] - HTTP method (POST or PATCH)
  /// [fields] - Form fields as key-value pairs
  /// [files] - List of multipart files to upload
  /// [requiresAuth] - Whether to include authentication header (default: true)
  /// [customHeaders] - Additional headers to include
  Future<http.Response> postMultipart(
    String endpoint, {
    String method = 'POST',
    Map<String, String>? fields,
    List<http.MultipartFile>? files,
    bool requiresAuth = true,
    Map<String, String>? customHeaders,
  }) async {
    final uri = endpoint.startsWith('http')
        ? Uri.parse(endpoint)
        : Uri.parse(endpoint);

    // Create multipart request
    final request = http.MultipartRequest(method, uri);

    // Add authentication header if required
    if (requiresAuth) {
      final token = await _authService.getAccessToken();
      if (token != null && token.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $token';
      }
    }

    // Add custom headers
    if (customHeaders != null) {
      request.headers.addAll(customHeaders);
    }

    // Add form fields
    if (fields != null) {
      request.fields.addAll(fields);
    }

    // Add files
    if (files != null) {
      request.files.addAll(files);
    }

    // Log request
    Logger.network('$method (multipart) $endpoint', tag: 'ApiService');
    if (fields != null) {
      Logger.debug('Form fields: $fields', tag: 'ApiService');
    }
    if (files != null) {
      Logger.debug('Files: ${files.length} file(s)', tag: 'ApiService');
    }

    try {
      // Send request
      final streamedResponse = await request.send().timeout(
        NetworkConstants.requestTimeout,
      );
      final response = await http.Response.fromStream(streamedResponse);

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

      // Handle 401 Unauthorized - try to refresh token and retry
      if (response.statusCode == 401 && requiresAuth) {
        Logger.info(
          'Received 401, attempting to refresh access token',
          tag: 'ApiService',
        );
        final refreshed = await _authService.refreshAccessToken();
        if (refreshed) {
          Logger.info(
            'Token refreshed, retrying original multipart request',
            tag: 'ApiService',
          );
          // Retry the request with new token
          return postMultipart(
            endpoint,
            method: method,
            fields: fields,
            files: files,
            requiresAuth: requiresAuth,
            customHeaders: customHeaders,
          );
        }
      }

      return response;
    } on http.ClientException catch (e) {
      Logger.error(
        'Network error: $method (multipart) $endpoint',
        error: e,
        tag: 'ApiService',
      );
      rethrow;
    } on Exception catch (e) {
      Logger.error(
        'Request error: $method (multipart) $endpoint',
        error: e,
        tag: 'ApiService',
      );
      rethrow;
    }
  }

  /// Internal method to make HTTP requests
  Future<http.Response> _makeRequest(
    String method,
    String endpoint, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
    Map<String, String>? customHeaders,
    bool isRetry = false,
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

      // Handle 401 Unauthorized - try to refresh token and retry
      if (response.statusCode == 401 && requiresAuth && !isRetry) {
        Logger.info(
          'Received 401, attempting to refresh access token',
          tag: 'ApiService',
        );
        final refreshed = await _authService.refreshAccessToken();
        if (refreshed) {
          Logger.info(
            'Token refreshed, retrying original request',
            tag: 'ApiService',
          );
          // Retry the request with new token
          return _makeRequest(
            method,
            endpoint,
            body: body,
            requiresAuth: requiresAuth,
            customHeaders: customHeaders,
            isRetry: true,
          );
        } else {
          Logger.warning(
            'Token refresh failed, returning 401 response',
            tag: 'ApiService',
          );
        }
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
