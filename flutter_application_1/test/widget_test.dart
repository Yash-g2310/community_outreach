// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build the main app widget (MyApp)
    await tester.pumpWidget(const MyApp(initialRoute: '/'));

    // Pump once to build the widget tree
    await tester.pump();

    // Verify that the splash screen loads correctly
    // The splash screen should show "Earn rewards for every ride you take."
    expect(find.text('Earn rewards for every ride you take.'), findsOneWidget);
    expect(find.text('Log In'), findsOneWidget);
    expect(find.text('Sign Up'), findsOneWidget);
  });
}
