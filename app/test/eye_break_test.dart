import 'package:dusty_library/core/server_config.dart';
import 'package:dusty_library/features/reader/eye_break.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pumpReader(WidgetTester tester, Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(p)],
        child: const MaterialApp(
          home: EyeBreakOverlay(child: Text('page')),
        ),
      ),
    );
  }

  testWidgets('no break when eye breaks are off', (tester) async {
    await pumpReader(tester, {});
    await tester.pump(const Duration(minutes: 30));
    expect(find.text('Rest your eyes'), findsNothing);
  });

  testWidgets('blurs after the interval, counts down, then clears', (tester) async {
    await pumpReader(tester, {
      'eye_break': true,
      'eye_break_minutes': 20,
      'eye_break_seconds': 20,
    });

    await tester.pump(const Duration(minutes: 19, seconds: 59));
    expect(find.text('Rest your eyes'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Rest your eyes'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('15'), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(find.text('Rest your eyes'), findsNothing);
  });

  testWidgets('skip ends the break and restarts the interval', (tester) async {
    await pumpReader(tester, {
      'eye_break': true,
      'eye_break_minutes': 30,
      'eye_break_seconds': 30,
    });
    await tester.pump(const Duration(minutes: 30));
    expect(find.text('30'), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Rest your eyes'), findsNothing);

    await tester.pump(const Duration(minutes: 29));
    expect(find.text('Rest your eyes'), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Rest your eyes'), findsOneWidget);
  });
}
