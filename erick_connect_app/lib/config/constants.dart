// Centralized constants for environment configuration
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../services/logger_service.dart';

/// Base API host for local development. Replace this value when deploying.
/// Falls back to hardcoded value if .env file is not available.
String get kBaseUrl {
  // Try to load from environment variable
  try {
    final envUrl = dotenv.env['BASE_URL'];
    if (envUrl != null && envUrl.isNotEmpty) {
      return envUrl;
    }
  } catch (e) {
    // Ignore errors when accessing dotenv
  }
  // Fallback to hardcoded value for backward compatibility
  return 'http://localhost:8000';
}

/// Convenience API base (optional): example usage `'$kBaseUrl/api/...'`
const String kApiPrefix = '/api';

/// Initialize environment configuration.
/// Should be called in main() before runApp().
/// Returns true if .env file was loaded successfully, false otherwise.
Future<bool> loadEnvConfig() async {
  try {
    // On Flutter Web, flutter_dotenv tries to load .env from assets folder
    // This requires .env to be listed in pubspec.yaml assets, which we avoid
    // to prevent committing sensitive data. For web, we'll skip .env loading
    // and use the fallback URL instead.
    if (kIsWeb) {
      Logger.debug(
        'Skipping .env loading on web (use fallback BASE_URL)',
        tag: 'Config',
      );
      return false;
    }

    // For mobile/desktop, try to load .env file from project root
    await dotenv.load(fileName: '.env');

    final baseUrl = dotenv.env['BASE_URL'];
    if (baseUrl != null && baseUrl.isNotEmpty) {
      Logger.info(
        'Environment config loaded: BASE_URL=$baseUrl',
        tag: 'Config',
      );
      return true;
    } else {
      Logger.debug(
        'Environment config: BASE_URL not found, using fallback',
        tag: 'Config',
      );
      return false;
    }
  } catch (e) {
    // .env file not found or error loading - use fallback
    // This is expected and handled gracefully
    Logger.debug(
      'Environment config: .env file not found or error loading, using fallback',
      tag: 'Config',
    );
    return false;
  }
}
