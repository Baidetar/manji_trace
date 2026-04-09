import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Framework smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('hello')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('hello'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
