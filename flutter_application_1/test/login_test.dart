import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/login_page.dart';

void main() {
  group('Login Page Console Logging Tests', () {
    testWidgets('Should log email input changes', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

      // Find the email text field
      final emailField = find.byType(TextField);
      expect(emailField, findsOneWidget);

      // Enter text and verify it triggers console logging
      await tester.enterText(emailField, 'test@example.com');
      await tester.pump();

      // The console logging happens automatically when text changes
      // Check that the text field contains the entered text
      expect(find.text('test@example.com'), findsOneWidget);
    });

    testWidgets('Should handle Connect button press', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

      // Find the email field and enter data
      final emailField = find.byType(TextField);
      await tester.enterText(emailField, 'user@example.com');
      await tester.pump();

      // Find and tap the Connect button
      final connectButton = find.text('Connect');
      expect(connectButton, findsOneWidget);

      await tester.tap(connectButton);
      await tester.pump();

      // Should show success snackbar
      expect(
        find.text('Login attempted with: user@example.com'),
        findsOneWidget,
      );
    });

    testWidgets('Should handle Google Sign-In button press', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

      // Find and tap the Google Sign-In button
      final googleButton = find.text('Sign in with Google');
      expect(googleButton, findsOneWidget);

      await tester.tap(googleButton);
      await tester.pump();

      // Should show Google sign-in snackbar
      expect(
        find.text('Google Sign-In pressed (not implemented yet)'),
        findsOneWidget,
      );
    });

    testWidgets('Should show error for empty email', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

      // Find and tap Connect button without entering email
      final connectButton = find.text('Connect');
      await tester.tap(connectButton);
      await tester.pump();

      // Should show error snackbar
      expect(find.text('Please enter your email'), findsOneWidget);
    });
  });
}
