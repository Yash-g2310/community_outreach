import 'dart:async';

import 'package:flutter/material.dart';
import 'config/constants.dart';
import 'config/app_constants.dart';
import 'router/app_router.dart';
import 'services/auth_service.dart';
import 'services/websocket_service.dart';
import 'core/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize environment configuration
  // This will load .env file if available, otherwise use fallback
  // Wrap in try-catch with timeout to prevent VM crashes
  try {
    await loadEnvConfig().timeout(
      NetworkConstants.envConfigTimeout,
      onTimeout: () => false,
    );
  } catch (e) {
    // Silently continue with fallback if env loading fails
    // This prevents crashes from file system issues
  }

  // Initialize auth service
  await AuthService().init();

  // Get initial route based on auth state
  final initialRoute = await AppRouter.getInitialRoute();

  runApp(MyApp(initialRoute: initialRoute));
}

class MyApp extends StatefulWidget {
  final String initialRoute;

  const MyApp({super.key, required this.initialRoute});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  AppLifecycleState? _lastLifecycleState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _lastLifecycleState;
    _lastLifecycleState = state;
    if (state == AppLifecycleState.resumed &&
        previous != null &&
        previous != AppLifecycleState.resumed) {
      unawaited(WebSocketService().recoverConnectionsAfterResume());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      initialRoute: widget.initialRoute,
      onGenerateRoute: AppRouter.generateRoute,
      title: 'E-Rick Connect',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode:
          ThemeMode.system, // Automatically switch based on system settings
    );
  }
}
