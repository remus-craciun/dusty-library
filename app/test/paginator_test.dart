import 'dart:convert';
import 'dart:typed_data';

import 'package:dusty_library/features/reader/text/paginator.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ahem (the test font) draws every glyph as a square of the font size, so
/// line breaks and heights are predictable.
const _style = TextStyle(fontFamily: 'Ahem', fontSize: 10, height: 1.5);

PageLayout _layout({
  double width = 200,
  double height = 100,
  TextStyle style = _style,
}) =>
    PageLayout(style: style, width: width, height: height, paragraphSpacing: 6);

List<String> _book() => [
  for (var i = 0; i < 40; i++)
    List.generate(3 + (i * 7) % 60, (w) => 'w$i-$w').join(' '),
];

double _sliceHeight(List<String> paras, PageSlice s, PageLayout layout) {
  final p = TextPainter(
    text: TextSpan(
      text: paras[s.paragraph].substring(s.start, s.end),
      style: layout.style,
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: layout.width);
  final h = p.height;
  p.dispose();
  return h;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every page fits and the pages cover the text exactly once', () {
    final paras = _book();
    final layout = _layout();
    final pages = Paginator(paras, layout).runToEnd();
    expect(pages.length, greaterThan(10));

    final rebuilt = List.filled(paras.length, '');
    for (final page in pages) {
      var h = 0.0;
      for (var i = 0; i < page.slices.length; i++) {
        final s = page.slices[i];
        h +=
            (i == 0 ? 0 : layout.paragraphSpacing) +
            _sliceHeight(paras, s, layout);
        expect(
          s.start,
          rebuilt[s.paragraph].length,
          reason: 'slices are contiguous',
        );
        rebuilt[s.paragraph] += paras[s.paragraph].substring(s.start, s.end);
      }
      expect(h, lessThanOrEqualTo(layout.height + 0.01));
    }
    expect(rebuilt, paras);
  });

  test('a paragraph longer than a page is split across pages', () {
    final long = List.generate(400, (i) => 'word$i').join(' ');
    final pages = Paginator(['Intro', long, 'Outro'], _layout()).runToEnd();
    final pieces = [
      for (final p in pages) ...p.slices.where((s) => s.paragraph == 1),
    ];
    expect(pieces.length, greaterThan(3));
    expect(pieces.first.start, 0);
    expect(pieces.last.end, long.length);
    // Splits fall on line starts: no word is cut.
    for (final s in pieces.skip(1)) {
      expect(long[s.start - 1], ' ');
    }
  });

  test('the reading spot survives a font size change', () {
    final paras = _book();
    final small = Paginator(paras, _layout()).runToEnd();
    final big = Paginator(
      paras,
      _layout(style: _style.copyWith(fontSize: 14)),
    ).runToEnd();
    expect(big.length, greaterThan(small.length));

    final page = small[small.length ~/ 2];
    final spot = TextSpot(page.first.paragraph, page.first.start);
    final shown = big[pageIndexFor(big, spot)];
    final from = TextSpot(shown.first.paragraph, shown.first.start);
    final to = TextSpot(shown.last.paragraph, shown.last.end);
    expect(from <= spot, isTrue);
    expect(spot <= to, isTrue);
  });

  test('stepping gives the same pages as one run', () {
    final paras = _book();
    final whole = Paginator(paras, _layout()).runToEnd();
    final stepped = Paginator(paras, _layout());
    var steps = 0;
    while (!stepped.step(3)) {
      steps++;
    }
    expect(steps, greaterThan(5));
    expect(
      [for (final p in stepped.pages) p.slices],
      [for (final p in whole) p.slices],
    );
  });

  test('pageIndexFor and pagesReach', () {
    final pages = Paginator(_book(), _layout()).runToEnd();
    expect(pageIndexFor(pages, const TextSpot(0, 0)), 0);
    expect(pageIndexFor(pages, const TextSpot(9999, 0)), pages.length - 1);
    expect(pagesReach(pages.sublist(0, 2), const TextSpot(39, 0)), isFalse);
    expect(pagesReach(pages, const TextSpot(39, 0)), isTrue);
  });

  test('decodeBookText reads the server JSON', () {
    final bytes = Uint8List.fromList(
      utf8.encode('{"paragraphs":["One","Twö"]}'),
    );
    expect(decodeBookText(bytes).paragraphs, ['One', 'Twö']);
  });

  group('notes', () {
    // Paragraph i (i odd) refers to a note at its end; note 3 is long enough
    // to need more than one page.
    final paras = _book();
    final notes = <BookNote>[
      for (var i = 1, n = 1; i < paras.length; i += 2, n++)
        BookNote(
          paragraph: i,
          offset: paras[i].length - 1,
          label: '$n',
          text: n == 3
              ? List.generate(300, (w) => 'note$w').join(' ')
              : 'Translation $n of the passage.',
        ),
    ];
    final layout = _layout(height: 160);

    double notesHeight(TextPage page) {
      if (page.notes.isEmpty) return 0;
      var h = layout.noteRuleHeight + layout.noteGap * (page.notes.length - 1);
      for (final n in page.notes) {
        final p = TextPainter(
          text: TextSpan(
            text: notes[n.note].display.substring(n.start, n.end),
            style: layout.noteStyle,
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: layout.width);
        h += p.height;
        p.dispose();
      }
      return h;
    }

    test('body and notes fit, notes start on the page that refers to them, '
        'and long notes continue', () {
      final pages = Paginator(paras, layout, notes: notes).runToEnd();
      final shown = List.filled(notes.length, '');
      final firstPage = <int, int>{};
      for (var p = 0; p < pages.length; p++) {
        final page = pages[p];
        var body = 0.0;
        for (var i = 0; i < page.slices.length; i++) {
          body +=
              (i == 0 ? 0 : layout.paragraphSpacing) +
              _sliceHeight(paras, page.slices[i], layout);
        }
        expect(
          body + notesHeight(page),
          lessThanOrEqualTo(layout.height + 0.5),
          reason: 'page $p',
        );
        for (final n in page.notes) {
          expect(
            n.start,
            shown[n.note].length,
            reason: 'note slices are contiguous',
          );
          shown[n.note] += notes[n.note].display.substring(n.start, n.end);
          firstPage.putIfAbsent(n.note, () => p);
        }
      }
      expect(shown, [for (final n in notes) n.display]);

      for (var i = 0; i < notes.length; i++) {
        final page = pages[firstPage[i]!];
        final hasMarker = page.slices.any(
          (s) =>
              s.paragraph == notes[i].paragraph &&
              s.start <= notes[i].offset &&
              notes[i].offset < s.end,
        );
        expect(
          hasMarker,
          isTrue,
          reason: 'note ${i + 1} starts beside its marker',
        );
      }
      final longPages = {
        for (var p = 0; p < pages.length; p++)
          if (pages[p].notes.any((n) => n.note == 2)) p,
      };
      expect(longPages.length, greaterThan(1));
    });

    test('the reading spot survives a font size change', () {
      final small = Paginator(paras, layout, notes: notes).runToEnd();
      final big = Paginator(
        paras,
        _layout(height: 160, style: _style.copyWith(fontSize: 14)),
        notes: notes,
      ).runToEnd();
      final spot = pageStart(small, small.length ~/ 2);
      final shown = big[pageIndexFor(big, spot)];
      final last = shown.slices.last;
      expect(pageStart(big, pageIndexFor(big, spot)) <= spot, isTrue);
      expect(spot <= TextSpot(last.paragraph, last.end), isTrue);
    });

    test('decodeBookText reads notes and defaults to none', () {
      final bytes = Uint8List.fromList(
        utf8.encode(
          '{"version":2,"paragraphs":["Hi¹"],"notes":[{"paragraph":0,"offset":2,"label":"1","text":"Salut"}]}',
        ),
      );
      final text = decodeBookText(bytes);
      expect(text.notes.single.display, '1. Salut');
      expect(
        decodeBookText(
          Uint8List.fromList(
            utf8.encode(
              '{"version":3,"paragraphs":["I"],"headings":[{"paragraph":0,"level":2,"title":"I"}]}',
            ),
          ),
        ).headings.single.level,
        2,
      );
      expect(
        decodeBookText(Uint8List.fromList(utf8.encode('{"paragraphs":["a"]}')))
            .notes,
        isEmpty,
      );
    });
  });

  test('titles get pages of their own, a run of them sharing one', () {
    final paras = _book()
      ..[10] = 'Part Two'
      ..[11] = 'Chapter I'
      ..[25] = 'Chapter II';
    final pages = Paginator(paras, _layout(), titles: {10, 11, 25}).runToEnd();
    List<int> parasOn(TextPage p) => [for (final s in p.slices) s.paragraph];
    final part = pages.indexWhere((p) => parasOn(p).contains(10));
    expect(parasOn(pages[part]), [10, 11]);
    expect(pages[part].title, isTrue);
    expect(parasOn(pages[part + 1]).first, 12);
    expect(pages[part + 1].title, isFalse);
    expect(parasOn(pages[part - 1]).last, 9);

    final chapter = pages.indexWhere((p) => parasOn(p).contains(25));
    expect(parasOn(pages[chapter]), [25]);
    expect(pages[chapter].title, isTrue);
    expect(pages.where((p) => p.title).length, 2);
  });
}
