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

        return const UserMapScreen();
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

        return const DriverPage();
      },
    );
  }

  // ============================================================
  // Navigation Helper Methods
  // ============================================================

  /// Push a new route onto the navigator
  static Future<T?> push<T extends Object?>(
    BuildContext context,
    Widget page, {
    RouteSettings? settings,
  }) {
    return Navigator.push<T>(
      context,
      MaterialPageRoute(
        builder: (_) => page,
        settings: settings,
      ),
    );
  }

  /// Push a named route onto the navigator
  static Future<T?> pushNamed<T extends Object?>(
    BuildContext context,
    String routeName, {
    Object? arguments,
  }) {
    return Navigator.pushNamed<T>(
      context,
      routeName,
      arguments: arguments,
    );
  }

  /// Replace the current route with a new route
  static Future<T?> pushReplacement<T extends Object?, TO extends Object?>(
    BuildContext context,
    Widget page, {
    RouteSettings? settings,
    TO? result,
  }) {
    return Navigator.pushReplacement<T, TO>(
      context,
      MaterialPageRoute(
        builder: (_) => page,
        settings: settings,
      ),
      result: result,
    );
  }

  /// Replace the current named route with a new named route
  static Future<T?> pushReplacementNamed<T extends Object?, TO extends Object?>(
    BuildContext context,
    String routeName, {
    Object? arguments,
    TO? result,
  }) {
    return Navigator.pushReplacementNamed<T, TO>(
      context,
      routeName,
      arguments: arguments,
      result: result,
    );
  }

  /// Push a route and remove all previous routes
  static Future<T?> pushAndRemoveUntil<T extends Object?>(
    BuildContext context,
    Widget page,
    bool Function(Route<dynamic>) predicate, {
    RouteSettings? settings,
  }) {
    return Navigator.pushAndRemoveUntil<T>(
      context,
      MaterialPageRoute(
        builder: (_) => page,
        settings: settings,
      ),
      predicate,
    );
  }

  /// Push a named route and remove all previous routes
  static Future<T?> pushNamedAndRemoveUntil<T extends Object?>(
    BuildContext context,
    String routeName,
    bool Function(Route<dynamic>) predicate, {
    Object? arguments,
  }) {
    return Navigator.pushNamedAndRemoveUntil<T>(
      context,
      routeName,
      predicate,
      arguments: arguments,
    );
  }

  /// Pop the current route
  static void pop<T extends Object?>(BuildContext context, [T? result]) {
    Navigator.pop<T>(context, result);
  }

  /// Check if the navigator can pop
  static bool canPop(BuildContext context) {
    return Navigator.canPop(context);
  }
}
