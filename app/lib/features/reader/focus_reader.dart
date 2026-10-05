import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:pdfrx/pdfrx.dart';

import 'reading_position.dart';

/// Lets the reader screen drive a [FocusReader] (go to page).
class FocusReaderController {
  Future<void> Function(int pageNumber)? _goTo;
  Future<void> Function(int direction)? _turn;
  void Function(double delta)? _scrollBy;

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
/// The horizontal crop is shared by the whole document (a robust percentile of
/// the text edges across pages) so the text size stays constant from page to
/// page; only the vertical trim is per page. Pages without any text (scans,
/// full-page figures) are shown whole.
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
    required this.onTap,
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

  /// A tap on the page, with the position and size of the reader.
  final void Function(Offset localPosition, Size viewSize) onTap;
  final FocusReaderController? controller;

  @override
  State<FocusReader> createState() => _FocusReaderState();
}

class _FocusReaderState extends State<FocusReader> {
  PdfDocument? _doc;
  _FocusLayout? _layout;
  Object? _error;
  int _measured = 0;
  int _total = 0;

  final _scroll = ScrollController();
  double _layoutWidth = 0;
  List<double> _heights = const [];
  List<double> _offsets = const []; // cumulative, length = pages + 1
  int _page = 1;
  double _pageOffset = 0;
  bool _initialJumpDone = false;

  /// Ignores scroll events while a programmatic jump is in flight, so opening
  /// a book does not overwrite the saved spot with the top of the first page.
  bool _suppress = true;

  @override
  void initState() {
    super.initState();
    widget.controller?._goTo = _goToPage;
    widget.controller?._turn = _turn;
    widget.controller?._scrollBy = _scrollBy;
    _scroll.addListener(_onScroll);
    _open();
  }

  @override
  void didUpdateWidget(covariant FocusReader old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._goTo = null;
      old.controller?._turn = null;
      old.controller?._scrollBy = null;
      widget.controller?._goTo = _goToPage;
      widget.controller?._turn = _turn;
      widget.controller?._scrollBy = _scrollBy;
    }
  }

  @override
  void dispose() {
    widget.controller?._goTo = null;
    widget.controller?._turn = null;
    widget.controller?._scrollBy = null;
    _scroll.dispose();
    _doc?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final doc = await PdfDocument.openData(widget.bytes, sourceName: widget.sourceName);
      if (!mounted) {
        doc.dispose();
        return;
      }
      _doc = doc;
      _total = doc.pages.length;
      final layout = await _FocusLayout.measure(
        doc,
        cacheKey: '${widget.sourceName}:${widget.bytes.length}',
        onProgress: (n) {
          if (mounted) setState(() => _measured = n);
        },
      );
      if (!mounted) return;
      _page = widget.initialPage.clamp(1, _total);
      _pageOffset = widget.initialPageOffset.clamp(0.0, 1.0);
      setState(() => _layout = layout);
      widget.onReady(_total);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  // --- geometry -----------------------------------------------------------

  void _relayout(double width) {
    final layout = _layout!;
    _layoutWidth = width;
    _heights = [for (final c in layout.crops) c.height * (width / c.width)];
    final offsets = List<double>.filled(_heights.length + 1, 0);
    for (var i = 0; i < _heights.length; i++) {
      offsets[i + 1] = offsets[i] + _heights[i];
    }
    _offsets = offsets;
  }

  List<FocusPage> get _focusPages => focusPages(
    crops: _layout!.crops,
    pageHeights: [for (final p in _doc!.pages) p.height],
    viewTops: _offsets.sublist(0, _heights.length),
    viewHeights: _heights,
  );

  void _onScroll() {
    if (_suppress || _heights.isEmpty || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final ReadingSpot spot;
    if (pos.pixels >= pos.maxScrollExtent - 1) {
      // The end of the book is on screen: remember the bottom of the last page.
      spot = ReadingSpot(_heights.length, 1);
    } else {
      spot = focusReadingSpot(scrollTop: pos.pixels, pages: _focusPages);
    }
    _page = spot.page;
    _pageOffset = spot.offset;
    widget.onPositionChanged(spot.page, spot.offset);
  }

  void _scrollBy(double delta) {
    if (!_scroll.hasClients || delta == 0) return;
    final pos = _scroll.position;
    _scroll.jumpTo((pos.pixels + delta).clamp(0.0, pos.maxScrollExtent));
  }

  Future<void> _turn(int direction) async {
    if (!_scroll.hasClients || direction == 0) return;
    final pos = _scroll.position;
    final target = (pos.pixels + direction * pos.viewportDimension).clamp(0.0, pos.maxScrollExtent);
    await _scroll.animateTo(target, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
  }

  Future<void> _goToPage(int pageNumber) async {
    if (_offsets.isEmpty || !_scroll.hasClients) return;
    final idx = (pageNumber - 1).clamp(0, _heights.length - 1);
    final target = _offsets[idx].clamp(0.0, _scroll.position.maxScrollExtent);
    await _scroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
  }

  void _jumpToSavedSpot() {
    if (!_scroll.hasClients) {
      _suppress = false;
      return;
    }
    final pages = _focusPages;
    final target = focusScrollOffset(spot: ReadingSpot(_page, _pageOffset), pages: pages);
    _suppress = true;
    _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
    _suppress = false;
  }

  // --- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text('Could not render PDF: $_error'));
    }
    final layout = _layout;
    if (layout == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(_total > 0 ? 'Measuring pages $_measured / $_total' : 'Opening…'),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width != _layoutWidth) {
          final widthChanged = _layoutWidth != 0;
          _relayout(width);
          if (!_initialJumpDone || widthChanged) {
            // Position after the list has laid out with the new extents.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _initialJumpDone = true;
              _jumpToSavedSpot();
            });
          }
        }
        final dpr = MediaQuery.devicePixelRatioOf(context);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => widget.onTap(details.localPosition, Size(width, constraints.maxHeight)),
          child: ColoredBox(
            color: widget.backgroundColor,
            child: ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.zero,
              itemCount: _heights.length,
              itemExtentBuilder: (i, _) => _heights[i],
              scrollCacheExtent: const ScrollCacheExtent.viewport(1),
              itemBuilder: (context, i) => _CroppedPage(
                key: ValueKey(i),
                page: _doc!.pages[i],
                crop: layout.crops[i],
                width: width,
                height: _heights[i],
                devicePixelRatio: dpr,
                backgroundColor: widget.backgroundColor,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Per-page crop rectangles (Flutter coordinates, PDF points).
class _FocusLayout {
  const _FocusLayout(this.crops);
  final List<Rect> crops;

  /// Crops are independent of the screen, so remember them per book for the
  /// lifetime of the app: re-opening a book in focus mode is then instant.
  static final _cache = <String, _FocusLayout>{};

  static const _padX = 3.0; // points kept around the text, horizontally
  static const _padY = 8.0; // and vertically

  static Future<_FocusLayout> measure(
    PdfDocument doc, {
    required String cacheKey,
    required ValueChanged<int> onProgress,
  }) async {
    final cached = _cache[cacheKey];
    if (cached != null && cached.crops.length == doc.pages.length) return cached;

    final bounds = <Rect?>[];
    for (var i = 0; i < doc.pages.length; i++) {
      bounds.add(await _textBounds(doc.pages[i]));
      onProgress(i + 1);
    }

    // Document-wide text column: robust percentiles so a lone wide table or a
    // title page does not dictate the crop for the whole book.
    final lefts = <double>[], rights = <double>[];
    for (final b in bounds) {
      if (b != null) {
        lefts.add(b.left);
        rights.add(b.right);
      }
    }
    final crops = <Rect>[];
    if (lefts.isEmpty) {
      for (final p in doc.pages) {
        crops.add(Rect.fromLTWH(0, 0, p.width, p.height));
      }
    } else {
      lefts.sort();
      rights.sort();
      final colLeft = _percentile(lefts, 0.05) - _padX;
      final colRight = _percentile(rights, 0.95) + _padX;
      for (var i = 0; i < doc.pages.length; i++) {
        final p = doc.pages[i];
        final b = bounds[i];
        if (b == null) {
          crops.add(Rect.fromLTWH(0, 0, p.width, p.height));
          continue;
        }
        final left = math.max(0.0, colLeft);
        final right = math.min(p.width, colRight);
        final top = math.max(0.0, b.top - _padY);
        final bottom = math.min(p.height, b.bottom + _padY);
        if (right - left < 8 || bottom - top < 8) {
          crops.add(Rect.fromLTWH(0, 0, p.width, p.height));
        } else {
          crops.add(Rect.fromLTRB(left, top, right, bottom));
        }
      }
    }
    final layout = _FocusLayout(List.unmodifiable(crops));
    _cache[cacheKey] = layout;
    return layout;
  }

  static double _percentile(List<double> sorted, double q) {
    final idx = ((sorted.length - 1) * q).round().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  /// Union of the glyph boxes on [page] in Flutter coordinates, or null when
  /// the page has no (usable) text.
  static Future<Rect?> _textBounds(PdfPage page) async {
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
      if (r.isEmpty || r.width > page.width * 0.5 || r.height > page.height * 0.5) continue;
      if (r.right < 0 || r.left > page.width || r.top < 0 || r.bottom > page.height) continue;
      acc = acc == null ? r : acc.merge(r);
    }
    if (acc == null) return null;
    final rect = acc.toRect(page: page);
    return rect.isEmpty ? null : rect;
  }
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
    if (old.width != widget.width || old.crop != widget.crop || old.devicePixelRatio != widget.devicePixelRatio) {
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
    final pixelWidth = math.min(_maxPixelWidth, (widget.width * widget.devicePixelRatio).round());
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
          : RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
    );
  }
}
