import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../reading_position.dart';
import '../word_lookup.dart';
import 'paginator.dart';

/// Lets the reader screen drive a [TextReader].
class TextReaderController {
  _TextReaderState? _state;

  /// Where the reader is, as a 1-based paragraph and the fraction of it
  /// before the first character on screen (the same shape the server keeps).
  ReadingSpot? get spot => _state?._readingSpot();

  /// 1-based page shown first, and the page count so far.
  int get page => (_state?._index ?? 0) + 1;
  int get pageCount => _state?._pages.length ?? 0;

  /// Moves one page. [direction] is 1 for forward and -1 for back.
  Future<void> turn(int direction) async => _state?._turn(direction);

  Future<void> goToPage(int pageNumber) async =>
      _state?._goToIndex(pageNumber - 1);

  /// 1-based page that shows the start of [paragraph] (0-based), or null
  /// while the pages up to it are still being laid out.
  int? pageOf(int paragraph) {
    final state = _state;
    if (state == null) return null;
    final spot = TextSpot(paragraph, 0);
    if (state._counting && !pagesReach(state._pages, spot)) return null;
    return pageIndexFor(state._pages, spot) + 1;
  }

  /// Shows the page holding character [offset] of [paragraph] (0-based).
  void showText(int paragraph, int offset) =>
      _state?._seek(TextSpot(paragraph, offset));
}

/// Kindle-style reader for extracted text: the text is laid out in pages that
/// exactly fit the screen, so nothing scrolls. Pages are recomputed when the
/// window or font size changes, keeping the passage being read on screen.
/// One page is shown at a time, centred, whatever the width of the window.
class TextReader extends StatefulWidget {
  const TextReader({
    super.key,
    required this.paragraphs,
    this.notes = const [],
    this.headings = const [],
    required this.controller,
    required this.fontScale,
    this.animatePages = true,
    required this.background,
    required this.foreground,
    this.initialParagraph = 1,
    this.initialOffset = 0,
    this.highlight = '',
    this.activeHit,
    this.onPositioned,
    this.onPositionChanged,
    this.onPagesChanged,
    this.onTap,
    this.onWord,
  });

  final List<String> paragraphs;

  /// Footnotes/endnotes, shown at the bottom of the page that refers to them.
  final List<BookNote> notes;

  /// Chapter and part titles: each gets a title page of its own (a run of
  /// them shares one), shown centred and larger by level.
  final List<BookHeading> headings;
  final TextReaderController controller;

  /// Multiplier on the base font size (the reader's "text size" setting).
  final double fontScale;

  /// Slide pages in when they turn; off, they change at once. The system's
  /// "reduce motion" setting turns it off too.
  final bool animatePages;
  final Color background;
  final Color foreground;

  /// Saved spot: 1-based paragraph and fraction through it.
  final int initialParagraph;
  final double initialOffset;

  /// Find-in-book query whose matches are marked, and the selected match
  /// (paragraph index, character offset) marked more strongly.
  final String highlight;
  final TextSpot? activeHit;

  /// Called once the saved spot is on screen.
  final VoidCallback? onPositioned;

  /// Called when the reader moves: 1-based paragraph and fraction through it.
  /// On the last page this is past the end (paragraph count, 1).
  final void Function(int paragraph, double offset)? onPositionChanged;

  /// Called when the shown page or page count changes. [counting] is true
  /// while later pages are still being laid out, so [total] may grow.
  final void Function(int page, int total, bool counting)? onPagesChanged;

  final void Function(Offset local, Size view)? onTap;
  final ValueChanged<String>? onWord;

  static const baseFontSize = 18.0;
  static const lineHeight = 1.55;

  @override
  State<TextReader> createState() => _TextReaderState();
}

class _TextReaderState extends State<TextReader> {
  static const _relayoutDelay = Duration(milliseconds: 150);

  PageLayout? _layout;
  List<TextPage> _pages = const [];
  int _index = 0;

  /// Which way the last move went: 1 forward, -1 back, 0 for a jump or a new
  /// layout (those fade instead of sliding).
  int _direction = 0;
  bool _counting = true;
  bool _positioned = false;

  /// What must stay on screen across a new layout: the first character of
  /// the page being read.
  late TextSpot _anchor;

  /// Set when a jump targets text not laid out yet.
  bool _seekPending = false;

  int _generation = 0;
  PageLayout? _wanted;
  Timer? _relayout;

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
    final last = widget.paragraphs.length - 1;
    final para = (widget.initialParagraph - 1)
        .clamp(0, math.max(0, last))
        .toInt();
    final len = widget.paragraphs.isEmpty ? 0 : widget.paragraphs[para].length;
    _anchor = TextSpot(
      para,
      (widget.initialOffset.clamp(0.0, 1.0) * len).round().toInt(),
    );
  }

  @override
  void didUpdateWidget(TextReader old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller._state == this) old.controller._state = null;
      widget.controller._state = this;
    }
  }

  @override
  void dispose() {
    _generation++;
    _relayout?.cancel();
    if (widget.controller._state == this) widget.controller._state = null;
    super.dispose();
  }

  // --- layout ----------------------------------------------------------------

  /// The text column for a view of [size]: a comfortable line length centred
  /// on the screen, with room above for the bars and below for the folio.
  (PageLayout, EdgeInsets) _measure(Size size) {
    final fontSize = TextReader.baseFontSize * widget.fontScale;
    final style = TextStyle(fontSize: fontSize, height: TextReader.lineHeight);
    final narrow = size.width < 600;
    final side = narrow ? 20.0 : 48.0;
    final top = narrow ? 40.0 : 56.0;
    final bottom = narrow ? 44.0 : 52.0;
    final maxColumn = math.max(280.0, fontSize * 36);
    final column = math.max(40.0, math.min(maxColumn, size.width - 2 * side));
    final height = math.max(
      fontSize * TextReader.lineHeight,
      size.height - top - bottom,
    );
    final layout = PageLayout(
      style: style,
      width: column.floorToDouble(),
      height: height.floorToDouble(),
      paragraphSpacing: (fontSize * 0.75).roundToDouble(),
      noteStyle: TextStyle(fontSize: fontSize * 0.78, height: 1.4),
      noteGap: (fontSize * 0.3).roundToDouble(),
      noteRuleHeight: (fontSize * 1.2).roundToDouble(),
    );
    return (layout, EdgeInsets.fromLTRB(side, top, side, bottom));
  }

  void _want(PageLayout layout) {
    if (layout == _wanted) return;
    _wanted = layout;
    _relayout?.cancel();
    // Called from build, so start on the next turn of the event loop.
    // Resizing a window fires many sizes; only lay out the one it stops at.
    _relayout = Timer(
      _layout == null ? Duration.zero : _relayoutDelay,
      () => _paginate(layout),
    );
  }

  Future<void> _paginate(PageLayout layout) async {
    if (layout == _layout) return;
    final generation = ++_generation;
    final paginator = Paginator(
      widget.paragraphs,
      layout,
      notes: widget.notes,
      titles: {for (final h in widget.headings) h.paragraph},
    );
    var swapped = false;

    void swapIn() {
      swapped = true;
      _layout = layout;
      _pages = paginator.pages;
      _seekPending = false;
      _index = pageIndexFor(_pages, _anchor);
    }

    while (true) {
      final finished = paginator.step(60);
      if (!mounted || generation != _generation) return;
      _counting = !finished;
      if (!swapped && (finished || pagesReach(paginator.pages, _anchor))) {
        setState(swapIn);
        if (!_positioned) {
          _positioned = true;
          widget.onPositioned?.call();
        }
      } else if (swapped &&
          _seekPending &&
          (finished || pagesReach(_pages, _anchor))) {
        setState(() {
          _seekPending = false;
          _index = pageIndexFor(_pages, _anchor);
        });
        _reportPosition();
      } else if (swapped) {
        // The page count grew: refresh the folio.
        setState(() {});
      }
      if (swapped) _reportPages();
      if (finished) return;
      // Let a frame through between batches.
      await Future<void>.delayed(Duration.zero);
    }
  }

  // --- navigation ------------------------------------------------------------

  void _turn(int direction) {
    if (_pages.isEmpty || direction == 0) return;
    _goToIndex(_index + direction);
  }

  void _goToIndex(int index) {
    if (_pages.isEmpty) return;
    final target = index.clamp(0, _pages.length - 1);
    if (target == _index) return;
    setState(() {
      // One page either way is a turn; anything further is a jump.
      _direction = (target - _index).abs() == 1 ? (target - _index).sign : 0;
      _index = target;
      _anchor = pageStart(_pages, target);
      _seekPending = false;
    });
    _reportPages();
    _reportPosition();
  }

  void _seek(TextSpot spot) {
    _anchor = spot;
    if (_pages.isNotEmpty && (!_counting || pagesReach(_pages, spot))) {
      final target = pageIndexFor(_pages, spot);
      setState(() {
        _direction = 0;
        _index = target;
      });
      _reportPages();
      _reportPosition();
    } else {
      _seekPending = true;
    }
  }

  bool get _onLastPage => !_counting && _index + 1 >= _pages.length;

  ReadingSpot? _readingSpot() {
    if (_pages.isEmpty) return null;
    if (_onLastPage) return ReadingSpot(widget.paragraphs.length, 1);
    final first = pageStart(_pages, _index);
    final len = widget.paragraphs[first.paragraph].length;
    return ReadingSpot(first.paragraph + 1, len == 0 ? 0 : first.offset / len);
  }

  void _reportPosition() {
    final spot = _readingSpot();
    if (spot != null) widget.onPositionChanged?.call(spot.page, spot.offset);
  }

  void _reportPages() {
    widget.onPagesChanged?.call(_index + 1, _pages.length, _counting);
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final (layout, padding) = _measure(size);
          _want(layout);
          final shown = _layout;
          if (shown == null || _pages.isEmpty) {
            return Center(
              child: CircularProgressIndicator(color: widget.foreground),
            );
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => widget.onTap?.call(d.localPosition, size),
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -250) _turn(1);
              if (v > 250) _turn(-1);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Padding(
                  padding: padding,
                  child: Center(child: _pageSwitcher(_pageView(_index, shown))),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: padding.bottom / 2 - 8,
                  child: IgnorePointer(child: _folio()),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Title size by heading depth: the outermost level (volume or part) is
  /// largest.
  Map<int, int> get _titleDepths {
    final headings = widget.headings;
    if (headings.isEmpty) return const {};
    final top = headings.map((h) => h.level).reduce(math.min);
    return {for (final h in headings) h.paragraph: h.level - top};
  }

  static const _titleScale = [1.8, 1.45, 1.2];

  /// A title page: the titles centred on the page, shrunk to fit if a long
  /// run would not.
  Widget _titlePageView(TextPage page, PageLayout layout) {
    final depths = _titleDepths;
    final base = layout.style.copyWith(
      color: widget.foreground,
      fontWeight: FontWeight.w500,
      height: 1.3,
    );
    return SizedBox(
      width: layout.width,
      height: layout.height,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: layout.width,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < page.slices.length; i++)
                          Padding(
                            padding: EdgeInsets.only(
                              top: i == 0 ? 0 : layout.paragraphSpacing * 1.5,
                            ),
                            child: _SliceText(
                              text: widget.paragraphs[page.slices[i].paragraph],
                              slice: page.slices[i],
                              style: base.copyWith(
                                fontSize:
                                    (base.fontSize ?? 18) *
                                    _titleScale[math.min(
                                      depths[page.slices[i].paragraph] ?? 2,
                                      _titleScale.length - 1,
                                    )],
                              ),
                              width: layout.width,
                              textAlign: TextAlign.center,
                              highlight: widget.highlight,
                              activeHit: widget.activeHit,
                              markColor: widget.foreground,
                              onWord: widget.onWord,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (page.notes.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _notesView(page.notes, layout),
              ),
          ],
        ),
      ),
    );
  }

  static const _turnDuration = Duration(milliseconds: 260);

  /// Changes pages: on a turn the new page slides in from the side it comes
  /// from while the old one slides out the other way, both fading; a jump or
  /// new layout just fades. With animation off the page changes at once.
  Widget _pageSwitcher(Widget page) {
    final key = ValueKey('page $_generation:$_index');
    final animate =
        widget.animatePages && !MediaQuery.of(context).disableAnimations;
    final direction = _direction.toDouble();
    return ClipRect(
      child: AnimatedSwitcher(
        duration: animate ? _turnDuration : Duration.zero,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final incoming = child.key == key;
          final from = Offset((incoming ? 1 : -1) * direction * 0.3, 0);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(begin: from, end: Offset.zero).animate(animation),
              child: child,
            ),
          );
        },
        child: KeyedSubtree(key: key, child: page),
      ),
    );
  }

  Widget _pageView(int index, PageLayout layout) {
    final page = _pages[index];
    if (page.title) return _titlePageView(page, layout);
    final style = layout.style.copyWith(color: widget.foreground);
    // Body text from the top, notes from the bottom, each exactly as tall as
    // the paginator measured; clipping only guards against rounding.
    return SizedBox(
      width: layout.width,
      height: layout.height,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < page.slices.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        top: i == 0 ? 0 : layout.paragraphSpacing,
                      ),
                      child: _SliceText(
                        text: widget.paragraphs[page.slices[i].paragraph],
                        slice: page.slices[i],
                        style: style,
                        width: layout.width,
                        highlight: widget.highlight,
                        activeHit: widget.activeHit,
                        markColor: widget.foreground,
                        onWord: widget.onWord,
                      ),
                    ),
                ],
              ),
            ),
            if (page.notes.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _notesView(page.notes, layout),
              ),
          ],
        ),
      ),
    );
  }

  /// The notes area: a short rule, then each note (or the part of it that
  /// fits here) in smaller type.
  Widget _notesView(List<NoteSlice> slices, PageLayout layout) {
    final ink = widget.foreground;
    final style = layout.noteStyle.copyWith(color: ink.withValues(alpha: 0.9));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: layout.noteRuleHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 48,
              height: 1,
              color: ink.withValues(alpha: 0.4),
            ),
          ),
        ),
        for (var i = 0; i < slices.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : layout.noteGap),
            child: RichText(
              textScaler: TextScaler.noScaling,
              text: TextSpan(
                style: style,
                text: widget.notes[slices[i].note].display.substring(
                  slices[i].start,
                  slices[i].end,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _folio() {
    final total = _pages.length;
    final label = 'Page ${_index + 1} of ${_counting ? '…' : total}';
    return Text(
      label,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: widget.foreground.withValues(alpha: 0.55),
        fontSize: 12,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// One paragraph (or the part of it on this page), with find matches marked
/// and a long press looking up the word under the finger.
class _SliceText extends StatelessWidget {
  const _SliceText({
    required this.text,
    required this.slice,
    required this.style,
    required this.width,
    required this.highlight,
    required this.activeHit,
    required this.markColor,
    this.textAlign = TextAlign.start,
    this.onWord,
  });

  final String text;
  final PageSlice slice;
  final TextStyle style;
  final double width;
  final TextAlign textAlign;
  final String highlight;
  final TextSpot? activeHit;
  final Color markColor;
  final ValueChanged<String>? onWord;

  String get _shown => text.substring(slice.start, slice.end);

  List<TextSpan> _spans() {
    final shown = _shown;
    final q = highlight.trim().toLowerCase();
    if (q.isEmpty) return [TextSpan(text: shown)];
    final lower = shown.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    while (true) {
      final at = lower.indexOf(q, from);
      if (at < 0) break;
      if (at > from) spans.add(TextSpan(text: shown.substring(from, at)));
      final hit = activeHit;
      final active =
          hit != null &&
          hit.paragraph == slice.paragraph &&
          hit.offset == slice.start + at;
      spans.add(
        TextSpan(
          text: shown.substring(at, at + q.length),
          style: TextStyle(
            backgroundColor: active
                ? const Color(0xCCE07A3D)
                : markColor.withValues(alpha: 0.22),
            color: active ? Colors.black : null,
          ),
        ),
      );
      from = at + q.length;
    }
    if (from < shown.length) spans.add(TextSpan(text: shown.substring(from)));
    return spans;
  }

  void _lookUp(Offset local) {
    final shown = _shown;
    final painter = TextPainter(
      text: TextSpan(text: shown, style: style),
      textAlign: textAlign,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(minWidth: width, maxWidth: width);
    final index = painter.getPositionForOffset(local).offset;
    painter.dispose();
    final word = wordAtIndex(shown, index) ?? wordAtIndex(shown, index - 1);
    if (word != null) onWord?.call(word);
  }

  @override
  Widget build(BuildContext context) {
    // Full column width, so a long-press maps to the same layout as
    // [_lookUp] measures (centred titles included).
    final rich = SizedBox(
      width: width,
      child: RichText(
        textAlign: textAlign,
        textScaler: TextScaler.noScaling,
        text: TextSpan(style: style, children: _spans()),
      ),
    );
    if (onWord == null) return rich;
    return GestureDetector(
      onLongPressStart: (d) => _lookUp(d.localPosition),
      child: rich,
    );
  }
}
