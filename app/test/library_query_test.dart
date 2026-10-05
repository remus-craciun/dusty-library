import 'package:dusty_library/data/models.dart';
import 'package:dusty_library/features/library/library_query.dart';
import 'package:dusty_library/features/reader/book_outline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

Book _book({
  required int id,
  required String title,
  String author = '',
  DateTime? lastReadAt,
  int currentPage = 1,
}) => Book(
  id: id,
  shelfId: 1,
  title: title,
  author: author,
  filename: '$id.pdf',
  sizeBytes: 1,
  pageCount: 100,
  currentPage: currentPage,
  lastReadAt: lastReadAt,
  createdAt: DateTime(2026),
);

void main() {
  test('search matches title or author and ignores case', () {
    final dune = _book(id: 1, title: 'Dune', author: 'Herbert');
    expect(bookMatchesQuery(dune, ''), isTrue);
    expect(bookMatchesQuery(dune, '  '), isTrue);
    expect(bookMatchesQuery(dune, 'dun'), isTrue);
    expect(bookMatchesQuery(dune, 'HERB'), isTrue);
    expect(bookMatchesQuery(dune, 'messiah'), isFalse);
  });

  test('continue reading is the latest last-read book', () {
    final older = _book(
      id: 1,
      title: 'Older',
      lastReadAt: DateTime(2026, 1, 1),
    );
    final newer = _book(
      id: 2,
      title: 'Newer',
      lastReadAt: DateTime(2026, 6, 1),
    );
    final unread = _book(id: 3, title: 'Unread');
    expect(continueReading([older, unread, newer])?.id, 2);
    expect(continueReading([unread]), isNull);
  });

  test('outline flattens nested entries and keeps page numbers', () {
    final nodes = [
      PdfOutlineNode(
        title: ' Part one ',
        dest: const PdfDest(2, PdfDestCommand.fit, null),
        children: [
          const PdfOutlineNode(
            title: '',
            dest: PdfDest(5, PdfDestCommand.fit, null),
            children: [],
          ),
          const PdfOutlineNode(title: 'Note', dest: null, children: []),
        ],
      ),
    ];
    final rows = flattenOutline(nodes);
    expect(rows.map((e) => (e.title, e.depth, e.pageNumber)).toList(), [
      ('Part one', 0, 2),
      ('Untitled', 1, 5),
      ('Note', 1, null),
    ]);
  });

  testWidgets('contents sheet lists outline rows and reports the tapped page', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => OutlineSheet(
                  nodes: const [
                    PdfOutlineNode(
                      title: 'Part one',
                      dest: PdfDest(2, PdfDestCommand.fit, null),
                      children: [],
                    ),
                  ],
                  onSelect: (page) => selected = page,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Part one'), findsOneWidget);
    await tester.tap(find.text('Part one'));
    await tester.pumpAndSettle();
    expect(selected, 2);
  });
}
