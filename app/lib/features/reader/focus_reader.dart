import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show ItemExtentBuilder, ScrollCacheExtent;
import 'package:pdfrx/pdfrx.dart';

import 'reading_position.dart';
import 'word_lookup.dart';

/// Lets the reader screen drive a [FocusReader] (go to page).
class FocusReaderController {
  Future<void> Function(int pageNumber)? _goTo;
  Future<void> Function(int direction)? _turn;
  void Function(double delta)? _scrollBy;
  ReadingSpot? Function()? _spot;

  /// Where the top of the focus view is, if it has been laid out.
  ReadingSpot? get spot => _spot?.call();

  Future<void> goToPage(int pageNumber) async => _goTo?.call(pageNumber);

  /// Moves by one screen. [direction] is 1 for forward and -1 for back.
  Future<void> turn(int direction) async => _turn?.call(direction);

  /// Scrolls by [delta] logical pixels. Positive moves down the book.
  void scrollBy(double delta) => _scrollBy?.call(delta);
}

/// "Focus mode" view of a PDF: every page is cropped to its text so the
/// paragraphs span the full width of the screen, with the blank page margins
/// removed. Pages flow vertically with no gaps, like one long sheet.
///
/// The text column is taken from the open page and a few pages around it, so
/// that page can appear before the rest of the book is measured. Later pages
/// keep that same column. Pages without any text (scans, full-page figures)
/// are shown whole.
class FocusReader extends StatefulWidget {
  const FocusReader({
    super.key,
    required this.bytes,
    required this.sourceName,
    required this.initialPage,
    this.initialPageOffset = 0,
    required this.backgroundColor,
    required this.onReady,
    required this.onPositionChanged,
    this.onPositioned,
    required this.onTap,
    this.onWord,
    this.controller,
  });

  final Uint8List bytes;
  final String sourceName;
  final int initialPage;

  /// Fraction down [initialPage] (full PDF page) to put at the top of the screen.
  final double initialPageOffset;
  final Color backgroundColor;
  final ValueChanged<int> onReady;
  final void Function(int page, double pageOffset) onPositionChanged;

  /// Called after the opening scroll has moved to [initialPage].
  final VoidCallback? onPositioned;

  /// A tap on the page, with the position and size of the reader.
  final void Function(Offset localPosition, Size viewSize) onTap;

  /// A word under a long-press, when the page has selectable text there.
  final ValueChanged<String>? onWord;
  final FocusReaderController? controller;

  @override
  State<FocusReader> createState() => _FocusReaderState();
}

class _FocusReaderState extends State<FocusReader> {
  static const _anchorKey = ValueKey('focus-anchor');
  static const _batch = 5;

  PdfDocument? _doc;
  _FocusLayout? _layout;
  Object? _error;
  bool _ready = false;
  bool _closed = false;
  int _total = 0;
  int _anchorPage = 1;

  /// Created once the nearby pages are measured, aimed at the open page.
  /// That page is the scroll view's zero point, so pages measured later above
  /// it do not push it down the screen.
  ScrollController? _scroll;
  double _layoutWidth = 0;
  int _laidOutStart = -1;
  int _laidOutEnd = -1;
  List<double> _beforeHeights = const [];
  List<double> _afterHeights = const [];
  double _beforeExtent = 0;
  double _afterExtent = 0;
  List<FocusPage> _beforeFocus = const [];
  List<FocusPage> _afterFocus = const [];
  ItemExtentBuilder? _beforeExtentBuilder;
  ItemExtentBuilder? _afterExtentBuilder;
  int _page = 1;
  double _pageOffset = 0;
  int _jumpAttempts = 0;
  int _backgroundToken = 0;
  int? _priorityIndex;
  final _waiters = <int, List<Completer<void>>>{};

  /// Ignores scroll events while a programmatic jump is in flight, so opening
  /// a book does not overwrite the saved spot with the top of the first page.
  bool _suppress = true;
  final _pageText = <int, PdfPageText>{};

  int get _anchorIndex => _anchorPage - 1;

  String get _cacheKey => '${widget.sourceName}:${widget.bytes.length}';

  @override
  void initState() {
    super.initState();
    // Kept from the first frame. Measuring the nearby pages takes a moment,
    // and a later rebuild must not retarget the jump.
    _page = widget.initialPage < 1 ? 1 : widget.initialPage;
    _pageOffset = widget.initialPageOffset.clamp(0.0, 1.0);
    _anchorPage = _page;
    widget.controller?._goTo = _goToPage;
    widget.controller?._turn = _turn;
    widget.controller?._scrollBy = _scrollBy;
    widget.controller?._spot = _currentSpot;
    _open();
  }

  @override
  void didUpdateWidget(covariant FocusReader old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._goTo = null;
      old.controller?._turn = null;
      old.controller?._scrollBy = null;
      old.controller?._spot = null;
      widget.controller?._goTo = _goToPage;
      widget.controller?._turn = _turn;
      widget.controller?._scrollBy = _scrollBy;
      widget.controller?._spot = _currentSpot;
    }
  }

  @override
  void dispose() {
    _closed = true;
    _backgroundToken++;
    _cancelWaiters();
    widget.controller?._goTo = null;
    widget.controller?._turn = null;
    widget.controller?._scrollBy = null;
    widget.controller?._spot = null;
    _scroll?.removeListener(_onScroll);
    _scroll?.dispose();
    _doc?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final doc = await PdfDocument.openData(
        widget.bytes,
        sourceName: widget.sourceName,
      );
      if (!mounted || _closed) {
        doc.dispose();
        return;
      }
      _doc = doc;
      _total = doc.pages.length;
      if (_total == 0) {
        setState(() => _error = 'This PDF has no pages.');
        return;
      }
      _page = _page.clamp(1, _total);
      _pageOffset = _pageOffset.clamp(0.0, 1.0);
      _anchorPage = _page;
      widget.onReady(_total);

      final cached = _FocusLayout.cache[_cacheKey];
      if (cached != null && cached.pageCount == _total && cached.isComplete) {
        _layout = cached;
        if (!mounted || _closed) return;
        setState(() => _ready = true);
        return;
      }

      _layout = _FocusLayout(_total);
      final (start, end) = focusMeasureWindow(page: _page, pageCount: _total);
      await _measureBounds(start, end);
      if (!mounted || _closed) return;
      _layout!.lockColumn(doc.pages, start: start, end: end);
      _layout!.measuredStart = start;
      _layout!.measuredEnd = end;
      setState(() => _ready = true);
      unawaited(_measureRest());
    } catch (e) {
      if (mounted && !_closed) setState(() => _error = e);
    }
  }

  /// Measures text bounds for [start, end), then crops them once the column
  /// is known. Yields between pages so the open page stays responsive.
  Future<void> _measureBounds(int start, int end) async {
    final doc = _doc;
    final layout = _layout;
    if (doc == null || layout == null) return;
    for (var i = start; i < end; i++) {
      if (!mounted || _closed) return;
      if (layout.bounds[i] == null) {
        try {
          layout.bounds[i] = await _FocusLayout.textBounds(doc.pages[i]);
        } catch (_) {
          return;
        }
      }
      if (!mounted || _closed) return;
      if (layout.columnLocked && layout.crops[i] == null) {
        layout.crops[i] = layout.cropFor(doc.pages[i], layout.bounds[i]);
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _expandTo(int start, int end) async {
    await _measureBounds(start, end);
    final layout = _layout;
    if (!mounted || _closed || layout == null || layout.measuredStart == null) {
      return;
    }
    var coveredStart = start;
    var coveredEnd = end;
    while (coveredStart < coveredEnd && layout.crops[coveredStart] == null) {
      coveredStart++;
    }
    while (coveredEnd > coveredStart && layout.crops[coveredEnd - 1] == null) {
      coveredEnd--;
    }
    if (coveredStart >= coveredEnd) return;
    if (coveredEnd < layout.measuredStart! ||
        coveredStart > layout.measuredEnd!) {
      return;
    }
    layout.measuredStart = math.min(layout.measuredStart!, coveredStart);
    layout.measuredEnd = math.max(layout.measuredEnd!, coveredEnd);
  }

  Future<void> _measureRest() async {
    final token = ++_backgroundToken;
    while (mounted && !_closed && token == _backgroundToken) {
      final layout = _layout;
      if (layout == null || layout.measuredStart == null) return;
      if (layout.isComplete && _priorityIndex == null) {
        _FocusLayout.cache[_cacheKey] = layout;
        _releaseWaiters();
        return;
      }
      try {
        final priority = _priorityIndex;
        if (priority != null && !layout.containsIndex(priority)) {
          if (priority >= layout.measuredEnd!) {
            final next = math.min(
              layout.pageCount,
              layout.measuredEnd! + _batch,
            );
            await _expandTo(layout.measuredEnd!, next);
          } else {
            final next = math.max(0, layout.measuredStart! - _batch);
            await _expandTo(next, layout.measuredStart!);
          }
        } else {
          _priorityIndex = null;
          if (layout.measuredEnd! < layout.pageCount) {
            final next = math.min(
              layout.pageCount,
              layout.measuredEnd! + _batch,
            );
            await _expandTo(layout.measuredEnd!, next);
          } else if (layout.measuredStart! > 0) {
            final next = math.max(0, layout.measuredStart! - _batch);
            await _expandTo(next, layout.measuredStart!);
          }
        }
      } catch (_) {
        _cancelWaiters();
        return;
      }
      if (!mounted || _closed || token != _backgroundToken) return;
      setState(() {});
      _scheduleRelease();
    }
  }

  void _scheduleRelease() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) _releaseWaiters();
    });
  }

  void _cancelWaiters() {
    for (final pending in _waiters.values) {
      for (final waiter in pending) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
    _waiters.clear();
  }

  void _releaseWaiters() {
    final layout = _layout;
    if (layout == null) return;
    final done = <int>[];
    for (final index in _waiters.keys) {
      if (layout.containsIndex(index)) done.add(index);
    }
    for (final index in done) {
      for (final waiter in _waiters.remove(index)!) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
  }

  Future<void> _untilMeasured(int index) async {
    final layout = _layout;
    if (layout != null && layout.containsIndex(index)) return;
    final waiter = Completer<void>();
    (_waiters[index] ??= []).add(waiter);
    _priorityIndex = index;
    await waiter.future;
  }

  // --- geometry -----------------------------------------------------------

  double _viewHeight(Rect crop, PdfPage page, double width) {
    final cropWidth = crop.width <= 0 ? page.width : crop.width;
    if (cropWidth <= 0 || width <= 0) return 1;
    return crop.height * (width / cropWidth);
  }

  List<FocusPage> _focusSlice(int startIndex, List<double> heights) {
    final layout = _layout!;
    final doc = _doc!;
    var top = 0.0;
    final pages = <FocusPage>[];
    for (var i = 0; i < heights.length; i++) {
      final crop = layout.crops[startIndex + i]!;
      final page = doc.pages[startIndex + i];
      pages.add(
        FocusPage(
          viewTop: top,
          viewHeight: heights[i],
          cropTop: crop.top,
          cropHeight: crop.height,
          pageHeight: page.height,
        ),
      );
      top += heights[i];
    }
    return pages;
  }

  void _relayout(double width) {
    final layout = _layout!;
    final doc = _doc!;
    final start = layout.measuredStart!;
    final end = layout.measuredEnd!;
    _layoutWidth = width;
    _laidOutStart = start;
    _laidOutEnd = end;
    _beforeHeights = [
      for (var i = start; i < _anchorIndex; i++)
        _viewHeight(layout.crops[i]!, doc.pages[i], width),
    ];
    _afterHeights = [
      for (var i = _anchorIndex; i < end; i++)
        _viewHeight(layout.crops[i]!, doc.pages[i], width),
    ];
    _beforeExtent = _beforeHeights.fold(0.0, (sum, height) => sum + height);
    _afterExtent = _afterHeights.fold(0.0, (sum, height) => sum + height);
    _beforeFocus = _focusSlice(start, _beforeHeights);
    _afterFocus = _focusSlice(_anchorIndex, _afterHeights);
    final before = _beforeHeights;
    final after = _afterHeights;
    _beforeExtentBuilder = (index, _) {
      if (index < 0 || index >= before.length) return null;
      // Child 0 sits against the open page. Later children are further up.
      return before[before.length - 1 - index];
    };
    _afterExtentBuilder = (index, _) {
      if (index < 0 || index >= after.length) return null;
      return after[index];
    };
  }

  void _syncLayout(double width) {
    final widthChanged = _layoutWidth != 0 && width != _layoutWidth;
    final first = _scroll == null;
    _relayout(width);
    if (first) {
      _scroll = ScrollController(initialScrollOffset: _targetOffset());
      _scroll!.addListener(_onScroll);
    }
    if (first || widthChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _jumpToSavedSpot();
      });
    }
  }

  double _targetOffset() {
    if (_afterFocus.isEmpty) return 0;
    return focusAnchorScrollOffset(
      spot: ReadingSpot(_page, _pageOffset),
      anchorPage: _anchorPage,
      before: _beforeFocus,
      fromAnchor: _afterFocus,
    );
  }

  double _minOffset() => -_beforeExtent;

  double _maxOffset(ScrollPosition position) {
    final viewport = position.viewportDimension;
    if (viewport <= 0) return position.maxScrollExtent;
    return math.max(0.0, _afterExtent - viewport);
  }

  double _clampOffset(double target, ScrollPosition position) {
    return target.clamp(_minOffset(), _maxOffset(position)).toDouble();
  }

  void _onScroll() {
    final scroll = _scroll;
    if (_suppress ||
        _afterFocus.isEmpty ||
        scroll == null ||
        !scroll.hasClients) {
      return;
    }
    final pos = scroll.position;
    final ReadingSpot spot;
    final atEnd =
        _layout?.isComplete == true && pos.pixels >= _maxOffset(pos) - 1;
    if (atEnd) {
      spot = ReadingSpot(_total, 1);
    } else {
      spot = focusAnchorReadingSpot(
        scrollOffset: pos.pixels,
        anchorPage: _anchorPage,
        before: _beforeFocus,
        fromAnchor: _afterFocus,
      );
    }
    _page = spot.page;
    _pageOffset = spot.offset;
    widget.onPositionChanged(spot.page, spot.offset);
  }

  void _scrollBy(double delta) {
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients || delta == 0) return;
    final pos = scroll.position;
    scroll.jumpTo(_clampOffset(pos.pixels + delta, pos));
  }

  Future<void> _turn(int direction) async {
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients || direction == 0) return;
    final pos = scroll.position;
    final target = _clampOffset(
      pos.pixels + direction * pos.viewportDimension,
      pos,
    );
    await scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _goToPage(int pageNumber) async {
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients || _total == 0) return;
    final index = (pageNumber - 1).clamp(0, _total - 1);
    if (_layout?.containsIndex(index) != true) {
      await _untilMeasured(index);
    }
    if (!mounted || _closed || !scroll.hasClients) return;
    await scroll.animateTo(
      _clampOffset(_targetOffsetFor(index + 1, 0), scroll.position),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  double _targetOffsetFor(int page, double offset) {
    return focusAnchorScrollOffset(
      spot: ReadingSpot(page, offset),
      anchorPage: _anchorPage,
      before: _beforeFocus,
      fromAnchor: _afterFocus,
    );
  }

  ReadingSpot? _currentSpot() {
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients || _afterFocus.isEmpty) {
      return null;
    }
    return focusAnchorReadingSpot(
      scrollOffset: scroll.offset,
      anchorPage: _anchorPage,
      before: _beforeFocus,
      fromAnchor: _afterFocus,
    );
  }

  void _jumpToSavedSpot() {
    if (!mounted) return;
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients || _afterFocus.isEmpty) {
      _retryJump();
      return;
    }
    if (scroll.position.viewportDimension <= 0) {
      _retryJump();
      return;
    }
    _suppress = true;
    scroll.jumpTo(_clampOffset(_targetOffset(), scroll.position));
    _suppress = false;
    _jumpAttempts = 0;
    widget.onPositioned?.call();
  }

  void _retryJump() {
    if (_jumpAttempts >= 60) {
      _suppress = false;
      widget.onPositioned?.call();
      return;
    }
    _jumpAttempts++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToSavedSpot();
    });
  }

  Future<void> _onLongPress(Offset local) async {
    final word = await _wordAt(local);
    if (!mounted || word == null) return;
    widget.onWord?.call(word);
  }

  /// Maps a viewport point through the crop back onto the page's glyphs.
  Future<String?> _wordAt(Offset local) async {
    final doc = _doc;
    final layout = _layout;
    final scroll = _scroll;
    if (doc == null ||
        layout == null ||
        scroll == null ||
        !scroll.hasClients ||
        _afterHeights.isEmpty) {
      return null;
    }
    final hit = _hitPage(scroll.offset + local.dy);
    if (hit == null) return null;
    final (index, yInPage, height) = hit;
    final crop = layout.crops[index];
    if (crop == null || crop.width <= 0 || height <= 0 || _layoutWidth <= 0) {
      return null;
    }
    final point = Offset(
      crop.left + (local.dx / _layoutWidth) * crop.width,
      crop.top + (yInPage / height) * crop.height,
    );
    try {
      final text = _pageText[index] ??= await doc.pages[index]
          .loadStructuredText();
      if (!mounted) return null;
      final rects = [
        for (final rect in text.charRects) rect.toRect(page: doc.pages[index]),
      ];
      final glyph = charIndexAt(rects, point);
      if (glyph == null) return null;
      return wordAtIndex(text.fullText, glyph);
    } catch (_) {
      return null;
    }
  }

  (int, double, double)? _hitPage(double contentY) {
    if (contentY >= 0) {
      var y = contentY;
      for (var i = 0; i < _afterHeights.length; i++) {
        final height = _afterHeights[i];
        if (y < height) return (_anchorIndex + i, y, height);
        y -= height;
      }
      if (_afterHeights.isEmpty) return null;
      final last = _afterHeights.length - 1;
      return (_anchorIndex + last, _afterHeights[last], _afterHeights[last]);
    }
    final start = _layout?.measuredStart;
    if (start == null) return null;
    var remain = -contentY;
    for (var i = _anchorIndex - 1; i >= start; i--) {
      final height = _beforeHeights[i - start];
      if (remain <= height) return (i, height - remain, height);
      remain -= height;
    }
    return null;
  }

  Widget _tile(int pageIndex, double devicePixelRatio) {
    final crop = _layout!.crops[pageIndex]!;
    final height = pageIndex < _anchorIndex
        ? _beforeHeights[pageIndex - _layout!.measuredStart!]
        : _afterHeights[pageIndex - _anchorIndex];
    return _CroppedPage(
      key: ValueKey(pageIndex),
      page: _doc!.pages[pageIndex],
      crop: crop,
      width: _layoutWidth,
      height: height,
      devicePixelRatio: devicePixelRatio,
      backgroundColor: widget.backgroundColor,
    );
  }

  // --- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text('Could not render PDF: $_error'));
    }
    final layout = _layout;
    if (!_ready || layout == null || layout.measuredStart == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Opening…'),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (!width.isFinite || width <= 0) return const SizedBox.shrink();
        final rangeChanged =
            layout.measuredStart != _laidOutStart ||
            layout.measuredEnd != _laidOutEnd;
        if (_scroll == null || width != _layoutWidth || rangeChanged) {
          _syncLayout(width);
        }
        final scroll = _scroll;
        final beforeBuilder = _beforeExtentBuilder;
        final afterBuilder = _afterExtentBuilder;
        if (scroll == null || beforeBuilder == null || afterBuilder == null) {
          return const SizedBox.shrink();
        }
        final dpr = MediaQuery.devicePixelRatioOf(context);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => widget.onTap(
            details.localPosition,
            Size(width, constraints.maxHeight),
          ),
          onLongPressEnd: widget.onWord == null
              ? null
              : (details) => _onLongPress(details.localPosition),
          child: ColoredBox(
            color: widget.backgroundColor,
            child: CustomScrollView(
              controller: scroll,
              center: _anchorKey,
              scrollCacheExtent: const ScrollCacheExtent.viewport(1),
              slivers: [
                SliverVariedExtentList(
                  itemExtentBuilder: beforeBuilder,
                  delegate: ExactScrollExtentDelegate(
                    itemCount: _beforeHeights.length,
                    contentExtent: _beforeExtent,
                    builder: (context, index) =>
                        _tile(_anchorIndex - 1 - index, dpr),
                  ),
                ),
                SliverVariedExtentList(
                  key: _anchorKey,
                  itemExtentBuilder: afterBuilder,
                  delegate: ExactScrollExtentDelegate(
                    itemCount: _afterHeights.length,
                    contentExtent: _afterExtent,
                    builder: (context, index) =>
                        _tile(_anchorIndex + index, dpr),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Per-page crop rectangles (Flutter coordinates, PDF points).
///
/// The text column is fixed from the first measured window. Pages measured
/// afterwards reuse it, so the open page does not change width while the rest
/// of the book is prepared.
class _FocusLayout {
  _FocusLayout(this.pageCount)
    : crops = List<Rect?>.filled(pageCount, null),
      bounds = List<Rect?>.filled(pageCount, null);

  /// A finished book stays ready for the rest of the session.
  static final cache = <String, _FocusLayout>{};

  static const _padX = 3.0;
  static const _padY = 8.0;

  final int pageCount;
  final List<Rect?> crops;
  final List<Rect?> bounds;
  double? columnLeft;
  double? columnRight;
  bool columnLocked = false;
  int? measuredStart;
  int? measuredEnd;

  bool get isComplete => measuredStart == 0 && measuredEnd == pageCount;

  bool containsIndex(int index) =>
      measuredStart != null && index >= measuredStart! && index < measuredEnd!;

  void lockColumn(List<PdfPage> pages, {required int start, required int end}) {
    final lefts = <double>[];
    final rights = <double>[];
    for (var i = start; i < end; i++) {
      final box = bounds[i];
      if (box != null) {
        lefts.add(box.left);
        rights.add(box.right);
      }
    }
    if (lefts.isNotEmpty) {
      lefts.sort();
      rights.sort();
      columnLeft = _percentile(lefts, 0.05) - _padX;
      columnRight = _percentile(rights, 0.95) + _padX;
    }
    columnLocked = true;
    for (var i = start; i < end; i++) {
      crops[i] = cropFor(pages[i], bounds[i]);
    }
  }

  Rect cropFor(PdfPage page, Rect? box) {
    final leftEdge = columnLeft;
    final rightEdge = columnRight;
    if (box == null || leftEdge == null || rightEdge == null) {
      return Rect.fromLTWH(0, 0, page.width, page.height);
    }
    final left = math.max(0.0, leftEdge);
    final right = math.min(page.width, rightEdge);
    final top = math.max(0.0, box.top - _padY);
    final bottom = math.min(page.height, box.bottom + _padY);
    if (right - left < 8 || bottom - top < 8) {
      return Rect.fromLTWH(0, 0, page.width, page.height);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  static double _percentile(List<double> sorted, double q) {
    final idx = ((sorted.length - 1) * q).round().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  /// Union of the glyph boxes on [page] in Flutter coordinates, or null when
  /// the page has no (usable) text.
  static Future<Rect?> textBounds(PdfPage page) async {
    final PdfPageText text;
    try {
      text = await page.loadStructuredText();
    } catch (_) {
      return null;
    }
    final rects = text.charRects;
    final chars = text.fullText;
    PdfRect? acc;
    for (var i = 0; i < rects.length; i++) {
      final r = rects[i];
      // Skip whitespace and degenerate/oversized boxes (PDFium reports odd
      // rectangles for control characters and some spacing glyphs).
      if (i < chars.length && chars[i].trim().isEmpty) continue;
      if (r.isEmpty ||
          r.width > page.width * 0.5 ||
          r.height > page.height * 0.5) {
        continue;
      }
      if (r.right < 0 ||
          r.left > page.width ||
          r.top < 0 ||
          r.bottom > page.height) {
        continue;
      }
      acc = acc == null ? r : acc.merge(r);
    }
    if (acc == null) return null;
    final rect = acc.toRect(page: page);
    return rect.isEmpty ? null : rect;
  }
}

/// Builder delegate that reports the real height of the whole list.
///
/// A plain builder estimates that height from the children on the first
/// screen. When later pages are taller, the estimate runs out in the middle
/// of the book and a jump to a later page is stopped there.
class ExactScrollExtentDelegate extends SliverChildBuilderDelegate {
  ExactScrollExtentDelegate({
    required NullableIndexedWidgetBuilder builder,
    required int itemCount,
    required this.contentExtent,
  }) : super(builder, childCount: itemCount);

  /// Distance from the start of the first child to the end of the last one.
  final double contentExtent;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => contentExtent;
}

/// Renders one cropped page region to exactly [width] x [height] logical
/// pixels, at device resolution.
class _CroppedPage extends StatefulWidget {
  const _CroppedPage({
    super.key,
    required this.page,
    required this.crop,
    required this.width,
    required this.height,
    required this.devicePixelRatio,
    required this.backgroundColor,
  });

  final PdfPage page;
  final Rect crop;
  final double width;
  final double height;
  final double devicePixelRatio;
  final Color backgroundColor;

  @override
  State<_CroppedPage> createState() => _CroppedPageState();
}

class _CroppedPageState extends State<_CroppedPage> {
  static const _maxPixelWidth = 2048;

  ui.Image? _image;
  PdfPageRenderCancellationToken? _token;

  @override
  void initState() {
    super.initState();
    _render();
  }

  @override
  void didUpdateWidget(covariant _CroppedPage old) {
    super.didUpdateWidget(old);
    if (old.width != widget.width ||
        old.crop != widget.crop ||
        old.devicePixelRatio != widget.devicePixelRatio) {
      _render();
    }
  }

  @override
  void dispose() {
    _token?.cancel();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _render() async {
    _token?.cancel();
    final token = widget.page.createCancellationToken();
    _token = token;

    final crop = widget.crop;
    final pixelWidth = math.min(
      _maxPixelWidth,
      (widget.width * widget.devicePixelRatio).round(),
    );
    final scale = pixelWidth / crop.width;
    final fullWidth = widget.page.width * scale;
    final fullHeight = widget.page.height * scale;
    final x = (crop.left * scale).floor();
    final y = (crop.top * scale).floor();
    final w = math.min((crop.width * scale).ceil(), fullWidth.floor() - x);
    final h = math.min((crop.height * scale).ceil(), fullHeight.floor() - y);
    if (w <= 0 || h <= 0) return;

    try {
      final raw = await widget.page.render(
        x: x,
        y: y,
        width: w,
        height: h,
        fullWidth: fullWidth,
        fullHeight: fullHeight,
        backgroundColor: 0xffffffff,
        cancellationToken: token,
      );
      if (raw == null) return;
      final image = await raw.createImage();
      raw.dispose();
      if (!mounted || token.isCanceled) {
        image.dispose();
        return;
      }
      _image?.dispose();
      setState(() => _image = image);
    } catch (_) {
      // Leave the placeholder; a failed tile is better than a crash mid-read.
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: image == null
          ? ColoredBox(color: widget.backgroundColor)
          : RawImage(
              image: image,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
            ),
    );
  }
}
