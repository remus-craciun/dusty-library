import 'package:dusty_library/core/server_config.dart';
import 'package:dusty_library/features/reader/eye_break.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DateTime clock;

  setUp(() => clock = DateTime(2026, 1, 1));

  Future<void> pumpReader(
    WidgetTester tester,
    Map<String, Object> prefs, {
    Duration idleLimit = const Duration(hours: 10),
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(p)],
        child: MaterialApp(
          home: Scaffold(
            body: EyeBreakOverlay(
              idleLimit: idleLimit,
              now: () => clock,
              child: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => const SizedBox(
                        height: 200,
                        child: Center(child: Text('sheet')),
                      ),
                    ),
                    child: const Text('page'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Sends the app to the background for [away], then brings it back.
  void background(WidgetTester tester, Duration away) {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    clock = clock.add(away);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  const on20 = {
    'eye_break': true,
    'eye_break_minutes': 20,
    'eye_break_seconds': 20,
  };

  final onBreak = find.text('Rest your eyes');

  testWidgets('no break when eye breaks are off', (tester) async {
    await pumpReader(tester, {});
    await tester.pump(const Duration(minutes: 30));
    expect(onBreak, findsNothing);
  });

  testWidgets('blurs after the interval, counts down, then clears', (
    tester,
  ) async {
    await pumpReader(tester, on20);

    await tester.pump(const Duration(minutes: 19, seconds: 59));
    expect(onBreak, findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(); // the panel fades in on the next frame
    expect(onBreak, findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('15'), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(onBreak, findsNothing);
  });

  testWidgets('skip ends the break and restarts the interval', (tester) async {
    await pumpReader(tester, {
      'eye_break': true,
      'eye_break_minutes': 30,
      'eye_break_seconds': 30,
    });
    await tester.pump(const Duration(minutes: 30));
    await tester.pump();
    expect(find.text('30'), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(onBreak, findsNothing);

    await tester.pump(const Duration(minutes: 29));
    expect(onBreak, findsNothing);
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(onBreak, findsOneWidget);
  });

  testWidgets('time in the background counts as a break', (tester) async {
    await pumpReader(tester, on20);
    await tester.pump(const Duration(minutes: 15));

    background(tester, const Duration(seconds: 30));

    await tester.pump(const Duration(minutes: 19, seconds: 59));
    expect(onBreak, findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(onBreak, findsOneWidget);
  });

  testWidgets('a short trip to the background does not reset the count', (
    tester,
  ) async {
    await pumpReader(tester, on20);
    await tester.pump(const Duration(minutes: 15));

    background(tester, const Duration(seconds: 5));

    await tester.pump(const Duration(minutes: 5));
    await tester.pump();
    expect(onBreak, findsOneWidget);
  });

  testWidgets(
    'no input for the idle limit stops the count; input restarts it',
    (tester) async {
      await pumpReader(tester, on20, idleLimit: const Duration(minutes: 5));

      await tester.pump(const Duration(minutes: 25));
      expect(onBreak, findsNothing);

      await tester.tap(find.text('page'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('sheet'))).pop();
      await tester.pumpAndSettle();

      // Keep reading, with a tap every few minutes.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(minutes: 4));
        await tester.tapAt(const Offset(5, 5));
      }
      // Opening and closing the sheet took a moment, so allow a few seconds.
      await tester.pump(const Duration(minutes: 3, seconds: 50));
      expect(onBreak, findsNothing);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(onBreak, findsOneWidget);
    },
  );

  testWidgets('the blur covers an open sheet and blocks it', (tester) async {
    await pumpReader(tester, on20);
    await tester.tap(find.text('page'));
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsOneWidget);

    await tester.pump(const Duration(minutes: 20));
    await tester.pump();
    expect(onBreak, findsOneWidget);

    // A tap on the sheet's spot lands on the break panel, not the sheet.
    final hit = tester.hitTestOnBinding(tester.getCenter(find.text('sheet')));
    final panel = tester.renderObject(find.byType(BackdropFilter));
    expect(hit.path.any((e) => e.target == panel), isTrue);
  });

  testWidgets('vibrates when a break ends on its own, not on skip', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') calls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpReader(tester, on20);
    await tester.pump(const Duration(minutes: 20));
    await tester.pump();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);

    await tester.pump(const Duration(minutes: 20, seconds: 20));
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, hasLength(2));
  });
}
