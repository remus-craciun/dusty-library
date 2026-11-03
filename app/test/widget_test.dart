import 'package:dusty_library/features/reader/text/paginator.dart';
import 'package:dusty_library/features/reader/text/text_contents.dart';
import 'package:dusty_library/features/reader/text/text_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps a [TextReader] over a book of [count] paragraphs in an 800x600 view.
Future<
  ({
    TextReaderController controller,
    List<(int, double)> positions,
    List<int> pages,
  })
>
_pumpReader(WidgetTester tester, {int count = 60, double fontScale = 1}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final controller = TextReaderController();
  final positions = <(int, double)>[];
  final pages = <int>[];
  final paragraphs = [
    for (var i = 0; i < count; i++)
      'Paragraph $i. ${List.filled(20 + i % 30, 'lorem ipsum').join(' ')}',
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: TextReader(
        paragraphs: paragraphs,
        controller: controller,
        fontScale: fontScale,
        background: Colors.black,
        foreground: Colors.grey,
        onPositionChanged: (p, o) => positions.add((p, o)),
        onPagesChanged: (page, total, counting) => pages.add(page),
      ),
    ),
  );
  // Let pagination run to the end.
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return (controller: controller, positions: positions, pages: pages);
}

void main() {
  testWidgets('text pages fit the view and turn without scrolling', (
    tester,
  ) async {
    final r = await _pumpReader(tester);
    expect(r.controller.pageCount, greaterThan(5));
    expect(r.controller.page, 1);
    expect(find.byType(Scrollable), findsNothing);
    expect(tester.takeException(), isNull);

    await r.controller.turn(1);
    await tester.pumpAndSettle();
    expect(r.controller.page, 2);
    expect(r.positions.last.$1, greaterThan(1));

    await r.controller.turn(-1);
    await tester.pumpAndSettle();
    expect(r.controller.page, 1);
    expect(r.positions.last, (1, 0.0));

    // Going to the end reports the position past the last paragraph.
    await r.controller.goToPage(r.controller.pageCount);
    await tester.pumpAndSettle();
    expect(r.positions.last, (60, 1.0));
  });

  testWidgets('a swipe turns the page', (tester) async {
    final r = await _pumpReader(tester);
    await tester.fling(find.byType(TextReader), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(r.controller.page, 2);
  });

  testWidgets('larger text gives more pages', (tester) async {
    final small = await _pumpReader(tester);
    final smallCount = small.controller.pageCount;
    final big = await _pumpReader(tester, fontScale: 1.6);
    expect(big.controller.pageCount, greaterThan(smallCount));
  });

  testWidgets('a note shows at the bottom of the page that refers to it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = TextReaderController();
    await tester.pumpWidget(
      MaterialApp(
        home: TextReader(
          paragraphs: [
            'Eh bien, mon prince.¹ She smiled.',
            for (var i = 0; i < 40; i++) 'Filler paragraph $i ${'word ' * 40}',
          ],
          notes: const [
            BookNote(
              paragraph: 0,
              offset: 20,
              label: '1',
              text: 'Ei bine, prinţe.',
            ),
          ],
          controller: controller,
          fontScale: 1,
          background: Colors.black,
          foreground: Colors.grey,
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final note = find.textContaining('1. Ei bine, prinţe.', findRichText: true);
    expect(note, findsOneWidget);
    // The note sits below the text it belongs to.
    final marker = find.textContaining('mon prince.¹', findRichText: true);
    expect(
      tester.getTopLeft(note).dy,
      greaterThan(tester.getBottomLeft(marker).dy),
    );
    expect(tester.takeException(), isNull);

    await controller.turn(1);
    await tester.pumpAndSettle();
    expect(note, findsNothing);
  });

  testWidgets('contents lists headings with pages and jumps to a chapter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = TextReaderController();
    final paragraphs = [
      'Volume One',
      'Chapter I',
      for (var i = 0; i < 30; i++) 'Filler $i ${'word ' * 40}',
      'Chapter II',
      for (var i = 0; i < 30; i++) 'More $i ${'word ' * 40}',
    ];
    const headings = [
      BookHeading(paragraph: 0, level: 1, title: 'Volume One'),
      BookHeading(paragraph: 1, level: 2, title: 'Chapter I'),
      BookHeading(paragraph: 32, level: 2, title: 'Chapter II'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextReader(
            paragraphs: paragraphs,
            controller: controller,
            fontScale: 1,
            background: Colors.black,
            foreground: Colors.grey,
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final chapterTwoPage = controller.pageOf(32)!;
    expect(chapterTwoPage, greaterThan(2));

    // Opened over the reader, as the reader screen does.
    showModalBottomSheet<void>(
      context: tester.element(find.byType(TextReader)),
      isScrollControlled: true,
      builder: (ctx) => TextContentsSheet(
        headings: headings,
        current: currentHeading(headings, 5),
        pageOf: controller.pageOf,
        onSelect: (p) {
          Navigator.pop(ctx);
          controller.showText(p, 0);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Volume One'), findsOneWidget);
    expect(find.text('$chapterTwoPage'), findsOneWidget);
    final current = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Chapter I'),
        matching: find.byType(ListTile),
      ),
    );
    expect(current.selected, isTrue);

    await tester.tap(find.text('Chapter II'));
    await tester.pumpAndSettle();
    expect(find.byType(TextContentsSheet), findsNothing);
    expect(controller.page, chapterTwoPage);
  });

  test('currentHeading is the last heading at or before a paragraph', () {
    const h = [
      BookHeading(paragraph: 2, level: 1, title: 'A'),
      BookHeading(paragraph: 9, level: 2, title: 'B'),
    ];
    expect(currentHeading(h, 0), -1);
    expect(currentHeading(h, 2), 0);
    expect(currentHeading(h, 50), 1);
  });

  group('page animation', () {
    Future<TextReaderController> pump(WidgetTester tester, bool animate) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TextReaderController();
      await tester.pumpWidget(
        MaterialApp(
          home: TextReader(
            paragraphs: [
              for (var i = 0; i < 40; i++) 'Paragraph $i ${'word ' * 40}',
            ],
            controller: controller,
            fontScale: 1,
            animatePages: animate,
            background: Colors.black,
            foreground: Colors.grey,
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return controller;
    }

    // Pages on screen (the switcher keys each page "page <layout>:<index>").
    Finder pages() => find.byWidgetPredicate(
      (w) =>
          w is KeyedSubtree &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('page '),
    );

    testWidgets('a turn slides the new page in from the side', (tester) async {
      final controller = await pump(tester, true);
      await controller.turn(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-turn both pages are on screen, the new one entering from the right.
      expect(pages(), findsNWidgets(2));
      final slides = tester
          .widgetList<SlideTransition>(
            find.descendant(
              of: find.byType(AnimatedSwitcher),
              matching: find.byType(SlideTransition),
            ),
          )
          .map((t) => t.position.value.dx)
          .toList();
      expect(slides.any((dx) => dx > 0), isTrue);
      await tester.pumpAndSettle();
      expect(pages(), findsOneWidget);
      expect(controller.page, 2);
    });

    testWidgets('with animation off the page changes at once', (tester) async {
      final controller = await pump(tester, false);
      await controller.turn(1);
      await tester.pump();
      expect(pages(), findsOneWidget);
      expect(controller.page, 2);
    });
  });
}
