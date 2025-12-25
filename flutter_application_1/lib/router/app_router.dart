import 'package:flutter/material.dart';
import '../pages/splash_screen.dart';
import '../pages/auth/login_page.dart';
import '../pages/auth/signup_page.dart';
import '../pages/user/user_page.dart';
import '../pages/driver/driver_page.dart';
import '../services/auth_service.dart';

/// Centralized app routing configuration
class AppRouter {
  static const String splash = '/';
  static const String login = '/login';
  static const String signup = '/signup';
  static const String userHome = '/user';
  static const String driverHome = '/driver';

  /// Get the initial route based on authentication state
  static Future<String> getInitialRoute() async {
    final authService = AuthService();
    await authService.init();
    final isAuth = await authService.isAuthenticated();

    if (!isAuth) {
      return splash;
    }

    final role = await authService.getUserRole();
    if (role == 'driver') {
      return driverHome;
    } else {
      return userHome;
    }
  }

  /// Generate routes for the app
  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case splash:
        return MaterialPageRoute(
          builder: (_) => const StepRewardPage(),
          settings: settings,
        );

      case login:
        return MaterialPageRoute(
          builder: (_) => const LoginScreen(),
          settings: settings,
        );

      case signup:
        return MaterialPageRoute(
          builder: (_) => const SignupPage(),
          settings: settings,
        );

      case userHome:
        return MaterialPageRoute(
          builder: (context) => _buildUserPage(context),
          settings: settings,
        );

      case driverHome:
        return MaterialPageRoute(
          builder: (context) => _buildDriverPage(context),
          settings: settings,
        );

      default:
        return MaterialPageRoute(
          builder: (_) => const StepRewardPage(),
          settings: settings,
        );
    }
  }

  /// Build UserPage with auth data from AuthService
  static Widget _buildUserPage(BuildContext context) {
    return FutureBuilder<AuthState>(
      future: AuthService().getAuthState(),
      builder: (ctx, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final authState = snapshot.data;
        if (authState == null || !authState.isAuthenticated) {
          // Redirect to login if not authenticated
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(ctx).pushReplacementNamed(login);
          });
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return UserMapScreen(
          jwtToken: authState.accessToken,
          userData: authState.userData,
        );
      },
    );
  }

  /// Build DriverPage with auth data from AuthService
  static Widget _buildDriverPage(BuildContext context) {
    return FutureBuilder<AuthState>(
      future: AuthService().getAuthState(),
      builder: (ctx, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final authState = snapshot.data;
        if (authState == null || !authState.isAuthenticated) {
          // Redirect to login if not authenticated
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(ctx).pushReplacementNamed(login);
          });
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return DriverPage(
          jwtToken: authState.accessToken,
          userData: authState.userData,
        );
      },
    );
  }
}
