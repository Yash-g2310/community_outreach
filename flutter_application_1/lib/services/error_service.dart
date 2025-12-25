import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'logger_service.dart';

/// Centralized error handling service
/// Provides user-friendly error messages and consistent error display
class ErrorService {
  static final ErrorService _instance = ErrorService._internal();
  factory ErrorService() => _instance;
  ErrorService._internal();

  /// Get user-friendly error message from exception or HTTP response
  String getErrorMessage(dynamic error, {http.Response? response}) {
    // Handle HTTP response errors
    if (response != null) {
      return _getHttpErrorMessage(response);
    }

    // Handle network exceptions
    final errorStr = error.toString().toLowerCase();
    if (errorStr.contains('connection refused') ||
        errorStr.contains('failed host lookup') ||
        errorStr.contains('socketexception') ||
        errorStr.contains('network is unreachable')) {
      return 'Network error. Please check your internet connection.';
    }

    if (errorStr.contains('timeout') || errorStr.contains('timed out')) {
      return 'Request timed out. Please try again.';
    }

    // Handle specific exception messages
    if (error is Exception) {
      final message = error.toString();
      // Remove "Exception: " prefix if present
      if (message.startsWith('Exception: ')) {
        return message.substring(11);
      }
      return message;
    }

    // Generic error message
    return 'An unexpected error occurred. Please try again.';
  }

  /// Get user-friendly message from HTTP response
  String _getHttpErrorMessage(http.Response response) {
    switch (response.statusCode) {
      case 400:
        try {
          final body = response.body;
          // Try to extract error message from JSON response
          if (body.isNotEmpty) {
            // Simple extraction - could be improved with proper JSON parsing
            if (body.contains('"error"')) {
              // Extract error message from JSON
              final errorMatch = RegExp(
                r'"error"\s*:\s*"([^"]+)"',
              ).firstMatch(body);
              if (errorMatch != null) {
                return errorMatch.group(1) ??
                    'Invalid request. Please check your input.';
              }
            }
          }
        } catch (e) {
          Logger.debug('Error parsing error response: $e');
        }
        return 'Invalid request. Please check your input.';

      case 401:
        return 'Authentication failed. Please login again.';

      case 403:
        return 'Permission denied. Please login again.';

      case 404:
        return 'Resource not found.';

      case 500:
      case 502:
      case 503:
        return 'Server error. Please try again later.';

      default:
        return 'Request failed. Please try again.';
    }
  }

  /// Show error message in SnackBar
  void showError(BuildContext context, String message, {Duration? duration}) {
    if (!context.mounted) return;

    // Capture ScaffoldMessenger while context is still valid
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: duration ?? const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Dismiss',
          textColor: Colors.white,
          onPressed: () {
            // Use captured ScaffoldMessenger directly - safe even if context is disposed
            try {
              scaffoldMessenger.hideCurrentSnackBar();
            } catch (e) {
              // Ignore if SnackBar is already dismissed or context is invalid
              Logger.debug('Error hiding SnackBar: $e', tag: 'ErrorService');
            }
          },
        ),
      ),
    );

    Logger.error('Error shown to user: $message', tag: 'ErrorService');
  }

  /// Show success message in SnackBar
  void showSuccess(BuildContext context, String message, {Duration? duration}) {
    if (!context.mounted) return;

    // Capture ScaffoldMessenger while context is still valid
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: duration ?? const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () {
            // Use captured ScaffoldMessenger directly - safe even if context is disposed
            try {
              scaffoldMessenger.hideCurrentSnackBar();
            } catch (e) {
              // Ignore if SnackBar is already dismissed or context is invalid
              Logger.debug('Error hiding SnackBar: $e', tag: 'ErrorService');
            }
          },
        ),
      ),
    );

    Logger.info('Success message shown: $message', tag: 'ErrorService');
  }

  /// Handle error and show appropriate message
  void handleError(
    BuildContext context,
    dynamic error, {
    http.Response? response,
    String? customMessage,
  }) {
    final message = customMessage ?? getErrorMessage(error, response: response);
    showError(context, message);
  }

  /// Handle HTTP response and show error if needed
  bool handleHttpResponse(
    BuildContext context,
    http.Response response, {
    bool showSuccessMessage = false,
    String? successMessage,
  }) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (showSuccessMessage && successMessage != null) {
        showSuccess(context, successMessage);
      }
      return true;
    } else {
      handleError(context, null, response: response);
      return false;
    }
  }
}
