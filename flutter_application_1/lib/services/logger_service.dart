import 'package:flutter/foundation.dart';

/// Centralized logging service with log levels
/// Automatically disables debug logs in release mode for performance
class Logger {
  static const String _tagPrefix = '[E-Rick]';

  /// Log debug messages (only in debug mode)
  static void debug(String message, {String? tag}) {
    if (kDebugMode) {
      final tagStr = tag != null ? '[$tag]' : '';
      debugPrint('$_tagPrefix$tagStr DEBUG: $message');
    }
  }

  /// Log info messages (always shown in debug mode)
  static void info(String message, {String? tag}) {
    if (kDebugMode) {
      final tagStr = tag != null ? '[$tag]' : '';
      debugPrint('$_tagPrefix$tagStr INFO: $message');
    }
  }

  /// Log warning messages (always shown)
  static void warning(String message, {String? tag}) {
    final tagStr = tag != null ? '[$tag]' : '';
    debugPrint('$_tagPrefix$tagStr WARNING: $message');
  }

  /// Log error messages (always shown)
  static void error(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final tagStr = tag != null ? '[$tag]' : '';
    debugPrint('$_tagPrefix$tagStr ERROR: $message');
    if (error != null) {
      debugPrint('$_tagPrefix$tagStr Error Details: $error');
    }
    if (stackTrace != null && kDebugMode) {
      debugPrint('$_tagPrefix$tagStr Stack Trace: $stackTrace');
    }
  }

  /// Log network-related messages
  static void network(String message, {String? tag}) {
    if (kDebugMode) {
      final tagStr = tag != null ? '[$tag]' : '';
      debugPrint('$_tagPrefix$tagStr NETWORK: $message');
    }
  }

  /// Log WebSocket-related messages
  static void websocket(String message, {String? tag}) {
    if (kDebugMode) {
      final tagStr = tag != null ? '[$tag]' : '';
      debugPrint('$_tagPrefix$tagStr WEBSOCKET: $message');
    }
  }
}
