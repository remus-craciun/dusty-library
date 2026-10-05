import 'package:dusty_library/features/reader/focus_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pages added above the anchor leave the anchor where it is', (
    tester,
  ) async {
    const center = ValueKey('focus-anchor');
    final controller = ScrollController(initialScrollOffset: 40);
    var before = 1;

    Future<void> pump() {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              center: center,
              slivers: [
                SliverVariedExtentList(
                  itemExtentBuilder: (_, _) => 120,
                  delegate: ExactScrollExtentDelegate(
                    itemCount: before,
                    contentExtent: before * 120,
                    builder: (context, index) => Text('near $index'),
                  ),
                ),
                SliverVariedExtentList(
                  key: center,
                  itemExtentBuilder: (_, _) => 300,
                  delegate: ExactScrollExtentDelegate(
                    itemCount: 2,
                    contentExtent: 600,
                    builder: (context, index) => Text('page ${index + 10}'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    await pump();
    await tester.pump();
    expect(controller.offset, 40);
    expect(find.text('page 10'), findsOneWidget);

    before = 3;
    await pump();
    await tester.pump();
    expect(controller.offset, 40);
    expect(find.text('page 10'), findsOneWidget);

    controller.jumpTo(-20);
    await tester.pump();
    expect(find.text('near 0'), findsOneWidget);
    expect(find.text('near 2'), findsNothing);
  });

  testWidgets(
    'a jump past the first pages reaches that page when later pages are taller',
    (tester) async {
      // The first pages are short, so a list that guesses its length from
      // them stops around the middle. Page 603 sits much further down.
      const earlyPages = 400;
      const laterPages = 203;
      const earlyHeight = 80.0;
      const laterHeight = 700.0;
      final heights = <double>[
        for (var i = 0; i < earlyPages; i++) earlyHeight,
        for (var i = 0; i < laterPages; i++) laterHeight,
      ];
      final total = earlyPages * earlyHeight + laterPages * laterHeight;
      final target =
          earlyPages * earlyHeight + (602 - earlyPages) * laterHeight;
      final controller = ScrollController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                SliverVariedExtentList(
                  itemExtentBuilder: (index, _) => heights[index],
                  delegate: ExactScrollExtentDelegate(
                    itemCount: heights.length,
                    contentExtent: total,
                    builder: (context, index) => Text('${index + 1}'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        controller.position.maxScrollExtent,
        closeTo(total - controller.position.viewportDimension, 1),
      );
      controller.jumpTo(target);
      await tester.pump();

      expect(heights.length, 603);
      expect(controller.offset, closeTo(target, 1));
      expect(find.text('603'), findsOneWidget);
      expect(find.text('1'), findsNothing);
    },
  );
}
