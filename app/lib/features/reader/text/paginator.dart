import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../data/local_cache.dart' show bookTextVersion;

/// A footnote or endnote of a text book. Its marker (the [label] in
/// superscript digits) is part of paragraph [paragraph] at [offset].
@immutable
class BookNote {
  const BookNote({
    required this.paragraph,
    required this.offset,
    required this.label,
    required this.text,
  });

  final int paragraph;
  final int offset;
  final String label;
  final String text;

  /// What the notes area shows: the number, then the text.
  String get display => '$label. $text';

  factory BookNote.fromJson(Map<String, dynamic> j) => BookNote(
    paragraph: (j['paragraph'] as num).toInt(),
    offset: (j['offset'] as num).toInt(),
    label: j['label'] as String,
    text: j['text'] as String,
  );
}

/// A title the document marks (volume, part, chapter...) for the contents.
/// [level] 1 is the outermost.
@immutable
class BookHeading {
  const BookHeading({
    required this.paragraph,
    required this.level,
    required this.title,
  });

  final int paragraph;
  final int level;
  final String title;

  factory BookHeading.fromJson(Map<String, dynamic> j) => BookHeading(
    paragraph: (j['paragraph'] as num).toInt(),
    level: (j['level'] as num).toInt(),
    title: j['title'] as String,
  );
}

/// The text of a Word document as served by `GET /api/books/{id}/text`.
class BookText {
  const BookText({
    required this.paragraphs,
    this.notes = const [],
    this.headings = const [],
    this.version = bookTextVersion,
  });

  final List<String> paragraphs;
  final List<BookNote> notes;
  final List<BookHeading> headings;
  final int version;
}

BookText decodeBookText(Uint8List bytes) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  return BookText(
    paragraphs: (json['paragraphs'] as List).cast<String>(),
    notes: [
      for (final n in (json['notes'] as List?) ?? const [])
        BookNote.fromJson(n as Map<String, dynamic>),
    ],
    headings: [
      for (final h in (json['headings'] as List?) ?? const [])
        BookHeading.fromJson(h as Map<String, dynamic>),
    ],
    version: (json['version'] as num?)?.toInt() ?? 1,
  );
}

/// A run of one paragraph shown on a page: characters [start, end).
@immutable
class PageSlice {
  const PageSlice(this.paragraph, this.start, this.end);
  final int paragraph;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is PageSlice &&
      other.paragraph == paragraph &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(paragraph, start, end);

  @override
  String toString() => 'PageSlice($paragraph, $start, $end)';
}

/// Part of a note shown at the bottom of a page: characters [start, end)
/// of [BookNote.display]. A note too long for one page continues on the
/// next ones.
@immutable
class NoteSlice {
  const NoteSlice(this.note, this.start, this.end);
  final int note;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is NoteSlice &&
      other.note == note &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(note, start, end);

  @override
  String toString() => 'NoteSlice($note, $start, $end)';
}

/// One screenful: body text (whole paragraphs, plus at most a split one at
/// either end) and the notes referenced on it, shown at the bottom. A page
/// at the very end may hold only the rest of a long note.
@immutable
class TextPage {
  const TextPage(this.slices, [this.notes = const [], this.title = false]);
  final List<PageSlice> slices;
  final List<NoteSlice> notes;

  /// A title page: it holds only headings (a part or chapter title, or a
  /// run of them such as "Part Two" + "Chapter I").
  final bool title;

  /// First and last body slice (pages with only notes have none; see
  /// [pageStart]).
  PageSlice get first => slices.first;
  PageSlice get last => slices.last;
}

/// A position in the text: a paragraph index and a character in it.
@immutable
class TextSpot {
  const TextSpot(this.paragraph, this.offset);
  final int paragraph;
  final int offset;

  bool operator <=(TextSpot o) =>
      paragraph < o.paragraph ||
      (paragraph == o.paragraph && offset <= o.offset);

  @override
  bool operator ==(Object other) =>
      other is TextSpot &&
      other.paragraph == paragraph &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(paragraph, offset);

  @override
  String toString() => 'TextSpot($paragraph, $offset)';
}

/// How text is laid out on a page. Two layouts are equal when they produce
/// the same pages, which is what decides whether to paginate again.
@immutable
class PageLayout {
  const PageLayout({
    required this.style,
    required this.width,
    required this.height,
    required this.paragraphSpacing,
    this.noteStyle = const TextStyle(fontSize: 14, height: 1.4),
    this.noteGap = 4,
    this.noteRuleHeight = 21,
    this.noteShare = 0.6,
  });

  final TextStyle style;

  /// Width of the text column and height of the page, in pixels.
  final double width;
  final double height;

  /// Vertical gap between paragraphs on the same page.
  final double paragraphSpacing;

  /// Notes: their text style, the gap between two notes, and the height of
  /// the band holding the rule that separates them from the text above.
  final TextStyle noteStyle;
  final double noteGap;
  final double noteRuleHeight;

  /// Largest share of a page the notes may take while text remains (a note's
  /// first line always goes on the page that refers to it).
  final double noteShare;

  @override
  bool operator ==(Object other) =>
      other is PageLayout &&
      other.style == style &&
      other.width == width &&
      other.height == height &&
      other.paragraphSpacing == paragraphSpacing &&
      other.noteStyle == noteStyle &&
      other.noteGap == noteGap &&
      other.noteRuleHeight == noteRuleHeight &&
      other.noteShare == noteShare;

  @override
  int get hashCode => Object.hash(
    style,
    width,
    height,
    paragraphSpacing,
    noteStyle,
    noteGap,
    noteRuleHeight,
    noteShare,
  );
}

/// Line breaks of one note's [BookNote.display] at the page width.
class _NoteLines {
  _NoteLines(this.heights, this.starts, this.length);
  final List<double> heights;
  final List<int> starts; // first character of each line
  final int length;

  int get count => heights.length;
  int end(int line) => line < count ? starts[line] : length;
}

/// Splits paragraphs into pages that fit [layout] exactly, never cutting a
/// line in half. Notes go at the bottom of the page whose text refers to
/// them; one too long for that page continues at the bottom of the next.
/// Paragraphs in [titles] (part and chapter headings) get pages of their
/// own: a run of consecutive titles shares one title page, and the text
/// after it starts on the next page.
///
/// Run it all at once with [runToEnd], or a slice at a time with [step] so a
/// long book does not hold up the UI.
///
/// Measurement uses [TextPainter] with no text scaling, so pages must be
/// drawn with the same styles, width and [TextScaler.noScaling] (as
/// [RichText] does by default).
class Paginator {
  Paginator(
    this.paragraphs,
    this.layout, {
    this.notes = const [],
    this.titles = const {},
  }) {
    for (var i = 0; i < notes.length; i++) {
      (_anchors[notes[i].paragraph] ??= []).add(i);
    }
    for (final list in _anchors.values) {
      list.sort((a, b) => notes[a].offset.compareTo(notes[b].offset));
    }
  }

  final List<String> paragraphs;
  final List<BookNote> notes;
  final Set<int> titles;
  final PageLayout layout;

  final List<TextPage> pages = [];

  final Map<int, List<int>> _anchors = {};
  final Map<int, _NoteLines> _noteLines = {};

  int _para = 0;
  int _char = 0;

  // The page being filled.
  final List<PageSlice> _body = [];
  double _bodyUsed = 0;
  final List<NoteSlice> _pageNotes = [];
  double _notesUsed = 0; // includes the rule band once there is a note

  /// Notes still to finish on later pages: (note, first line not yet shown).
  final List<(int, int)> _carry = [];

  bool get done =>
      _para >= paragraphs.length &&
      _body.isEmpty &&
      _pageNotes.isEmpty &&
      _carry.isEmpty;

  /// Paragraphs handled so far, for a rough "how far along" figure.
  int get paragraphsDone => _para;

  /// Lays out at most [maxParagraphs] more paragraphs. Returns [done].
  bool step([int maxParagraphs = 40]) {
    final stop = _para + maxParagraphs;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    try {
      while (_para < paragraphs.length && _para < stop) {
        _layoutParagraph(painter);
      }
    } finally {
      painter.dispose();
    }
    if (_para >= paragraphs.length) _finish();
    return done;
  }

  List<TextPage> runToEnd() {
    while (!step(1 << 30)) {}
    return pages;
  }

  bool get _pageEmpty => _body.isEmpty && _pageNotes.isEmpty;

  /// Places the rest of the current paragraph, closing pages as they fill.
  void _layoutParagraph(TextPainter painter) {
    final text = paragraphs[_para];
    final anchors = _anchors[_para] ?? const <int>[];
    final h = layout.height;
    // A title page holds titles only: close the page where a run of titles
    // starts, and again where the text after it starts.
    if (_char == 0 &&
        _body.isNotEmpty &&
        titles.contains(_para) != titles.contains(_body.last.paragraph)) {
      _closePage();
    }
    while (true) {
      if (_pageEmpty && _carry.isNotEmpty) _placeCarried(h * layout.noteShare);

      final remaining = text.substring(_char);
      final gap = _body.isEmpty ? 0.0 : layout.paragraphSpacing;
      painter
        ..text = TextSpan(text: remaining, style: layout.style)
        ..layout(maxWidth: layout.width);
      final lines = painter.computeLineMetrics();

      // Line tops, and the most lines that fit before counting new notes.
      final tops = <double>[0];
      for (final l in lines) {
        tops.add(tops.last + l.height);
      }
      final room = h - _bodyUsed - gap - _notesUsed;
      var fit = 0;
      while (fit < lines.length && tops[fit + 1] <= room + 0.01) {
        fit++;
      }

      int splitAt(int k) {
        if (k >= lines.length) return text.length;
        final probe = Offset(0, tops[k] + lines[k].height / 2);
        var split = painter.getPositionForOffset(probe).offset;
        if (split <= 0) {
          split = painter.getLineBoundary(const TextPosition(offset: 0)).end;
          if (split <= 0) split = 1;
        }
        return _char + split;
      }

      List<int> anchoredBefore(int split) => [
        for (final n in anchors)
          if (notes[n].offset >= _char && notes[n].offset < split) n,
      ];

      // Give up lines until the notes they refer to can start on this page.
      var split = 0;
      var anchored = const <int>[];
      while (fit > 0) {
        split = splitAt(fit);
        anchored = anchoredBefore(split);
        final fits =
            anchored.isEmpty ||
            (_carry.isEmpty &&
                _bodyUsed +
                        gap +
                        tops[fit] +
                        _notesUsed +
                        _minNotes(anchored) <=
                    h + 0.01);
        if (fits) break;
        fit--;
      }
      if (fit == 0) {
        if (_body.isNotEmpty) {
          _closePage();
          continue;
        }
        if (_carry.isNotEmpty) {
          // Only an unfinished note stands in the way of the next note's
          // marker: let it have the whole page so it ends sooner.
          _placeCarried(h);
          _closePage();
          continue;
        }
        // Nothing of this paragraph fits even on a page without body text:
        // show one line anyway rather than never moving on (it is clipped).
        fit = 1;
        split = splitAt(1);
        anchored = anchoredBefore(split);
      }

      _body.add(PageSlice(_para, _char, split));
      _bodyUsed += gap + tops[fit];
      // A note too long for the space left continues on the next page; the
      // rest of this page still takes text, but no new notes until it ends.
      _placeAnchored(anchored);

      if (split >= text.length) {
        _para++;
        _char = 0;
        return;
      }
      _char = split;
      _closePage();
    }
  }

  /// Height the first lines of [anchored] notes add to the notes area.
  double _minNotes(List<int> anchored) {
    var add = 0.0;
    var count = _pageNotes.length;
    for (final n in anchored) {
      add += count == 0 ? layout.noteRuleHeight : layout.noteGap;
      add += _lines(n).heights.first;
      count++;
    }
    return add;
  }

  /// Puts [anchored] notes on this page, as much of each as fits; the rest
  /// carries over to the next page.
  void _placeAnchored(List<int> anchored) {
    final h = layout.height;
    final limit = math.max(h * layout.noteShare, 0.0);
    for (final n in anchored) {
      final room = math.min(limit, h - _bodyUsed);
      final next = _placeNote(n, 0, room, force: true);
      if (next < _lines(n).count) _carry.add((n, next));
    }
  }

  /// Continues notes from earlier pages at the top of this page's notes
  /// area, up to [limit] high. Whatever still does not fit carries on.
  void _placeCarried(double limit) {
    final pending = List.of(_carry);
    _carry.clear();
    for (var i = 0; i < pending.length; i++) {
      final (n, from) = pending[i];
      final next = _placeNote(n, from, limit, force: _pageNotes.isEmpty);
      if (next < _lines(n).count) {
        _carry
          ..add((n, next))
          ..addAll(pending.skip(i + 1));
        return;
      }
    }
  }

  /// Adds lines [from..] of note [n] while the notes area stays within
  /// [limit]. With [force], at least one line is added. Returns the first
  /// line left out.
  int _placeNote(int n, int from, double limit, {required bool force}) {
    final lines = _lines(n);
    // Continuing the note already last on this page extends that slice.
    final extend =
        _pageNotes.isNotEmpty &&
        _pageNotes.last.note == n &&
        _pageNotes.last.end == lines.starts[math.min(from, lines.count - 1)];
    final lead = extend
        ? 0.0
        : _pageNotes.isEmpty
        ? layout.noteRuleHeight
        : layout.noteGap;
    var used = _notesUsed + lead;
    var to = from;
    while (to < lines.count && used + lines.heights[to] <= limit + 0.01) {
      used += lines.heights[to];
      to++;
    }
    if (to == from) {
      if (!force) return from;
      used += lines.heights[to];
      to++;
    }
    if (extend) {
      final last = _pageNotes.removeLast();
      _pageNotes.add(NoteSlice(n, last.start, lines.end(to)));
    } else {
      _pageNotes.add(NoteSlice(n, lines.starts[from], lines.end(to)));
    }
    _notesUsed = used;
    return to;
  }

  _NoteLines _lines(int n) => _noteLines[n] ??= _measureNote(notes[n].display);

  _NoteLines _measureNote(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: layout.noteStyle),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: layout.width);
    final metrics = painter.computeLineMetrics();
    final heights = [for (final l in metrics) l.height];
    final starts = <int>[0];
    var top = 0.0;
    for (var i = 0; i + 1 < metrics.length; i++) {
      top += metrics[i].height;
      final probe = Offset(0, top + metrics[i + 1].height / 2);
      final start = painter.getPositionForOffset(probe).offset;
      starts.add(math.max(start, starts.last));
    }
    painter.dispose();
    if (heights.isEmpty) return _NoteLines([0], [0], text.length);
    return _NoteLines(heights, starts, text.length);
  }

  /// After the last paragraph: close the page, then give the rest of any
  /// long note pages of its own.
  void _finish() {
    while (true) {
      if (_pageEmpty && _carry.isNotEmpty) _placeCarried(layout.height);
      if (_pageEmpty) return;
      _closePage();
    }
  }

  void _closePage() {
    pages.add(
      TextPage(
        List.unmodifiable(_body),
        List.unmodifiable(_pageNotes),
        _body.isNotEmpty && _body.every((s) => titles.contains(s.paragraph)),
      ),
    );
    _body.clear();
    _pageNotes.clear();
    _bodyUsed = 0;
    _notesUsed = 0;
  }
}

/// The first character of body text on page [index], or of the nearest
/// earlier page with body text (pages holding only notes have none).
TextSpot pageStart(List<TextPage> pages, int index) {
  for (var i = index; i >= 0; i--) {
    if (pages[i].slices.isNotEmpty) {
      final f = pages[i].slices.first;
      return TextSpot(f.paragraph, f.start);
    }
  }
  return const TextSpot(0, 0);
}

/// Index of the page that shows [pos], given pages laid out so far (in
/// order). A position past the last laid-out page gives that last page.
int pageIndexFor(List<TextPage> pages, TextSpot pos) {
  if (pages.isEmpty) return 0;
  var lo = 0;
  var hi = pages.length - 1;
  // Last page with body text whose first character is at or before [pos].
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (pageStart(pages, mid) <= pos) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  while (lo > 0 && pages[lo].slices.isEmpty) {
    lo--;
  }
  return lo;
}

/// Whether the laid-out [pages] already reach [pos] (so [pageIndexFor] is
/// final for it).
bool pagesReach(List<TextPage> pages, TextSpot pos) {
  for (var i = pages.length - 1; i >= 0; i--) {
    if (pages[i].slices.isEmpty) continue;
    final l = pages[i].slices.last;
    return l.paragraph > pos.paragraph ||
        (l.paragraph == pos.paragraph && l.end > pos.offset);
  }
  return false;
}
