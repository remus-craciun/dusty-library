import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/library_repository.dart';
import '../../data/models.dart';
import '../library/dialogs.dart';
import '../library/library_providers.dart';
import 'focus_mode.dart';
import 'focus_reader.dart';
import 'reader_settings.dart';
import 'reading_position.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.bookId});
  final int bookId;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  static const _chromeAutoHide = Duration(seconds: 3);

  final _controller = PdfViewerController();
  final _focusController = FocusReaderController();
  final _downloadProgress = ValueNotifier<double>(0);

  Uint8List? _bytes;
  Object? _error;
  int? _page;
  double? _pageOffset;
  int _pageCount = 0;

  /// False until the viewer has jumped to the saved spot, so the opening
  /// layout (top of the page) is not stored over the real position.
  bool _acceptPosition = false;
  bool? _shownFocus;

  /// Zoom at which the current page spans the full view width. The user's
  /// "text size" setting is a multiplier on top of this.
  double? _fitWidthZoom;
  bool _chrome = true;
  Timer? _chromeTimer;
  bool _promptedCompletion = false;
  Timer? _saveTimer;
  int? _unsavedPage;
  double? _unsavedOffset;

  Book? get _book => ref.read(libraryProvider).asData?.value.book(widget.bookId);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onViewerMoved);
    _load();
    _scheduleChromeHide();
    _syncWakelock(ref.read(focusModeProvider));
  }

  /// Focus mode keeps the screen awake while the reader is open.
  void _syncWakelock(bool focus) {
    WakelockPlus.toggle(enable: focus).catchError((Object _) {});
  }

  Future<void> _load() async {
    try {
      final bytes = await ref
          .read(libraryRepositoryProvider)
          .openBook(widget.bookId, onProgress: (p) => _downloadProgress.value = p);
      ref.read(libraryProvider.notifier).markDownloaded(widget.bookId);
      if (mounted) setState(() => _bytes = bytes);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _chromeTimer?.cancel();
    _controller.removeListener(_onViewerMoved);
    _flushProgress();
    _downloadProgress.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WakelockPlus.disable().catchError((Object _) {});
    super.dispose();
  }

  // --- progress ------------------------------------------------------------

  void _onPageChanged(int? page) {
    if (page == null || page == _page) return;
    setState(() => _page = page);
    if (_pageCount > 0 && page >= _pageCount) _maybePromptCompletion();
  }

  /// The normal viewer reports every matrix change. Focus mode calls
  /// [_rememberPosition] directly.
  void _onViewerMoved() {
    if (!_acceptPosition || !_controller.isReady) return;
    final spot = readingSpot(
      viewportTop: _controller.visibleRect.top,
      pages: [for (final r in _controller.layout.pageLayouts) PageSpan(r.top, r.height)],
    );
    _rememberPosition(spot.page, spot.offset);
  }

  void _rememberPosition(int page, double offset) {
    final book = _book;
    // Restoring the saved spot nudges the viewer and reports that same spot.
    // Don't write it back: a newer position from another device must survive
    // merely reopening the book.
    final unchanged = book != null && page == book.currentPage && (offset - book.pageOffset).abs() < 0.002;
    if (unchanged && _unsavedPage == null) {
      _pageOffset = offset;
      if (page != _page && mounted) setState(() => _page = page);
      return;
    }
    final changedPage = page != _page;
    _pageOffset = offset;
    if (changedPage && mounted) setState(() => _page = page);
    _unsavedPage = page;
    _unsavedOffset = offset;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _flushProgress);
    if (_pageCount > 0 && page >= _pageCount) _maybePromptCompletion();
  }

  (int, double) _savedSpot(Book book) {
    final page = math.max(1, _page ?? book.currentPage);
    final offset = (_pageOffset ?? book.pageOffset).clamp(0.0, 1.0).toDouble();
    return (page, offset);
  }

  Future<void> _restoreReadingSpot() async {
    _acceptPosition = false;
    final book = _book;
    if (book != null && book.currentPage >= 1 && _controller.isReady) {
      final (page, offset) = _savedSpot(book);
      final index = (page - 1).clamp(0, _controller.pageCount - 1);
      final rect = _controller.layout.pageLayouts[index];
      final y = rect.top + offset * rect.height;
      await _controller.goToPosition(documentOffset: Offset(rect.left, y), duration: Duration.zero);
    }
    _acceptPosition = true;
  }

  void _flushProgress() {
    final page = _unsavedPage;
    final offset = _unsavedOffset;
    final book = _book;
    if (page == null || offset == null || book == null) return;
    _unsavedPage = null;
    _unsavedOffset = null;
    // Fire and forget: the notifier handles offline queuing.
    ref.read(libraryProvider.notifier).saveProgress(book, page, offset).catchError((Object e) => book);
  }

  void _maybePromptCompletion() {
    if (_promptedCompletion) return;
    final book = _book;
    final data = ref.read(libraryProvider).asData?.value;
    final completed = data?.shelfOfKind(ShelfKind.completed);
    if (book == null || completed == null || book.shelfId == completed.id) return;
    _promptedCompletion = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('You reached the last page.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Move to Completed',
          onPressed: () => ref.read(libraryProvider.notifier).moveBook(book, completed.id).catchError((Object e) {
            if (mounted) showError(context, e);
          }),
        ),
      ),
    );
  }

  // --- zoom ----------------------------------------------------------------

  /// Zoom that makes [page] exactly as wide as the view (no gutters).
  double? _computeFitWidth(PdfPage page, Size viewSize, double fallback) {
    if (viewSize.width <= 0 || page.width <= 0) return fallback > 0 ? fallback : null;
    return viewSize.width / page.width;
  }

  double get _relativeZoom => ref.read(readerSettingsProvider).asData?.value.zoom ?? 1.0;

  void _applyZoom(double relative, {Duration duration = const Duration(milliseconds: 200)}) {
    final fit = _fitWidthZoom;
    if (fit == null || !_controller.isReady) return;
    _controller.setZoom(_controller.centerPosition, fit * relative, duration: duration);
  }

  /// Keeps the page glued to the full width when the window or orientation changes.
  void _onViewSizeChanged(Size viewSize, Size? oldSize, PdfViewerController controller) {
    if (!controller.isReady || oldSize == null || viewSize.width == oldSize.width) return;
    final pageIndex = ((controller.pageNumber ?? 1) - 1).clamp(0, controller.pageCount - 1);
    final fit = _computeFitWidth(controller.pages[pageIndex], viewSize, 0);
    if (fit == null) return;
    _fitWidthZoom = fit;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyZoom(_relativeZoom, duration: Duration.zero);
    });
  }

  // --- chrome --------------------------------------------------------------

  void _scheduleChromeHide() {
    _chromeTimer?.cancel();
    _chromeTimer = Timer(_chromeAutoHide, () {
      if (mounted && _chrome) _setChrome(false);
    });
  }

  void _setChrome(bool visible) {
    if (_chrome == visible) return;
    setState(() => _chrome = visible);
    SystemChrome.setEnabledSystemUIMode(visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
    if (visible) _scheduleChromeHide();
  }

  void _toggleChrome() => _setChrome(!_chrome);

  /// Left 20% moves back one screen, right 20% moves forward, the middle
  /// toggles the bars. With edge taps off, any tap toggles the bars.
  void _onReaderTap(Offset local, Size view) {
    if (!ref.read(edgeTapProvider)) {
      _toggleChrome();
      return;
    }
    switch (tapZone(local.dx, view.width)) {
      case TapZone.previous:
        _turnPage(-1);
      case TapZone.next:
        _turnPage(1);
      case TapZone.center:
        _toggleChrome();
    }
  }

  /// [direction] is 1 to move forward one screen and -1 to move back.
  Future<void> _turnPage(int direction) async {
    if (ref.read(focusModeProvider)) {
      await _focusController.turn(direction);
      return;
    }
    if (!_controller.isReady || direction == 0) return;
    final visible = _controller.visibleRect;
    final limit = math.max(0.0, _controller.documentSize.height - visible.height);
    final top = (visible.top + direction * visible.height).clamp(0.0, limit);
    await _controller.goToPosition(
      documentOffset: Offset(visible.left, top),
      duration: const Duration(milliseconds: 220),
    );
  }

  /// Arrow keys on the web. A step is a short scroll, and holding the key repeats.
  static const _arrowStep = 72.0;

  void _scrollByArrow(int direction) {
    if (!kIsWeb || direction == 0) return;
    final delta = direction * _arrowStep;
    if (ref.read(focusModeProvider)) {
      _focusController.scrollBy(delta);
      return;
    }
    if (!_controller.isReady) return;
    final visible = _controller.visibleRect;
    final viewHeight = _controller.viewSize.height;
    if (viewHeight <= 0 || visible.height <= 0) return;
    final limit = math.max(0.0, _controller.documentSize.height - visible.height);
    final top = (visible.top + delta * visible.height / viewHeight).clamp(0.0, limit);
    _controller.goToPosition(documentOffset: Offset(visible.left, top), duration: Duration.zero);
  }

  /// Any interaction with the chrome keeps it around a bit longer.
  void _keepChrome() {
    if (_chrome) _scheduleChromeHide();
  }

  Future<void> _openSettings() async {
    _chromeTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => ReaderSettingsSheet(onZoomChanged: _applyZoom),
    );
    _scheduleChromeHide();
  }

  Future<void> _jumpToPage() async {
    _chromeTimer?.cancel();
    final v = await promptText(context, title: 'Go to page', label: '1 – $_pageCount', confirm: 'Go');
    final n = int.tryParse(v ?? '');
    if (n != null && n >= 1 && n <= _pageCount) {
      if (ref.read(focusModeProvider)) {
        await _focusController.goToPage(n);
      } else {
        await _controller.goToPage(pageNumber: n);
      }
    }
    _scheduleChromeHide();
  }

  void _toggleFocusMode() {
    _keepChrome();
    final on = !ref.read(focusModeProvider);
    ref.read(focusModeProvider.notifier).set(on);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(on ? 'Focus mode on: margins trimmed, screen stays awake.' : 'Focus mode off.'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final book = ref.watch(libraryProvider.select((s) => s.asData?.value.book(widget.bookId)));
    final settings = ref.watch(readerSettingsProvider).asData?.value ?? const ReaderSettings();
    final style = FilterStyle.of(settings.filter);
    final focus = ref.watch(focusModeProvider);
    ref.listen(focusModeProvider, (_, on) => _syncWakelock(on));
    if (_shownFocus != focus) {
      // The viewer that is about to mount starts at the top of a page.
      // Ignore that until it has moved to the saved spot.
      _shownFocus = focus;
      _acceptPosition = false;
    }

    if (book == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Book not found')));
    }

    final page = _page ?? book.currentPage;
    final total = _pageCount > 0 ? _pageCount : book.pageCount;
    final progress = total > 0 ? (page / total).clamp(0.0, 1.0) : 0.0;

    Widget body;
    if (_error != null) {
      body = _Message(
        icon: Icons.error_outline,
        text: describeError(_error!),
        action: FilledButton(
          onPressed: () => setState(() {
            _error = null;
            _load();
          }),
          child: const Text('Retry'),
        ),
      );
    } else if (_bytes == null) {
      body = Center(
        child: ValueListenableBuilder<double>(
          valueListenable: _downloadProgress,
          builder: (_, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 200, child: LinearProgressIndicator(value: v > 0 ? v : null)),
              const SizedBox(height: 12),
              Text(v > 0 ? 'Downloading ${(v * 100).round()}%' : 'Opening…'),
            ],
          ),
        ),
      );
    } else if (focus) {
      // Switching modes mid-read keeps the current page and the spot on it.
      final (savedPage, savedOffset) = _savedSpot(book);
      body = ColorFiltered(
        colorFilter: style.colorFilter,
        child: FocusReader(
          key: ValueKey('focus-${book.id}'),
          bytes: _bytes!,
          sourceName: 'book-${book.id}',
          initialPage: savedPage,
          initialPageOffset: savedOffset,
          backgroundColor: style.viewerBackground,
          controller: _focusController,
          onReady: (count) {
            _pageCount = count;
            if (book.pageCount != count) {
              ref.read(libraryProvider.notifier).setPageCount(book, count);
            }
            _acceptPosition = true;
            if (mounted) setState(() => _page = savedPage.clamp(1, count));
          },
          onPositionChanged: _rememberPosition,
          onTap: _onReaderTap,
        ),
      );
    } else {
      final initialPage = math.max(1, _page ?? book.currentPage);
      body = ColorFiltered(
        colorFilter: style.colorFilter,
        child: PdfViewer.data(
          _bytes!,
          sourceName: 'book-${book.id}',
          controller: _controller,
          initialPageNumber: initialPage,
          params: PdfViewerParams(
            // Edge to edge: no gutters, no gaps between pages, no shadow.
            backgroundColor: style.viewerBackground,
            margin: 0,
            pageDropShadow: null,
            boundaryMargin: EdgeInsets.zero,
            onViewerReady: (document, controller) {
              _pageCount = document.pages.length;
              if (book.pageCount != _pageCount) {
                ref.read(libraryProvider.notifier).setPageCount(book, _pageCount);
              }
              if (mounted) setState(() => _page = controller.pageNumber);
              _restoreReadingSpot();
            },
            onViewSizeChanged: _onViewSizeChanged,
            sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(
              // Allow zooming out to half the width and in to 8x.
              minScale: 0.1,
              useAlternativeFitScaleAsMinScale: false,
              calculateInitialZoom: (document, controller, fitZoom, coverZoom) {
                final idx = (initialPage - 1).clamp(0, document.pages.length - 1);
                Size viewSize;
                try {
                  viewSize = controller.viewSize;
                } catch (_) {
                  viewSize = Size.zero;
                }
                // coverZoom equals fit-width whenever the page is taller than the
                // view (the common case), so it is the right fallback.
                final fit = _computeFitWidth(document.pages[idx], viewSize, coverZoom) ?? fitZoom;
                _fitWidthZoom = fit;
                return fit * settings.zoom;
              },
            ),
            onPageChanged: _onPageChanged,
            onGeneralTap: (context, controller, details) {
              if (details.type == PdfViewerGeneralTapType.tap) {
                _onReaderTap(details.localPosition, controller.viewSize);
                return true;
              }
              return false;
            },
            loadingBannerBuilder: (_, _, _) => const Center(child: CircularProgressIndicator()),
            errorBannerBuilder: (_, error, _, _) => Center(child: Text('Could not render PDF: $error')),
          ),
        ),
      );
    }

    final chromeColor = style.chromeBackground.withValues(alpha: 0.92);

    return Scaffold(
      backgroundColor: style.chromeBackground,
      // The page owns the full viewport; the bars float over it.
      body: _arrowKeys(
        Stack(
          fit: StackFit.expand,
          children: [
          body,
          // Top bar.
          Align(
            alignment: Alignment.topCenter,
            child: _SlideIn(
              visible: _chrome,
              fromTop: true,
              child: Listener(
                onPointerDown: (_) => _keepChrome(),
                child: Material(
                  color: chromeColor,
                  child: SafeArea(
                    bottom: false,
                    child: SizedBox(
                      height: kToolbarHeight,
                      child: Row(
                        children: [
                          BackButton(color: style.chromeForeground),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  book.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: style.chromeForeground),
                                ),
                                if (book.author.isNotEmpty)
                                  Text(
                                    book.author,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: style.chromeForeground.withValues(alpha: 0.7),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: focus ? 'Leave focus mode' : 'Focus mode',
                            color: style.chromeForeground,
                            icon: FocusIcon(active: focus),
                            onPressed: _bytes != null ? _toggleFocusMode : null,
                          ),
                          IconButton(
                            tooltip: 'Go to page',
                            color: style.chromeForeground,
                            icon: const Icon(Icons.pin_outlined),
                            onPressed: _pageCount > 0 ? _jumpToPage : null,
                          ),
                          IconButton(
                            tooltip: 'Reading settings',
                            color: style.chromeForeground,
                            icon: const Icon(Icons.tune),
                            onPressed: _openSettings,
                          ),
                          IconButton(
                            tooltip: 'Edit title / author',
                            color: style.chromeForeground,
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () async {
                              _chromeTimer?.cancel();
                              await editBookDetails(context, ref, book);
                              _scheduleChromeHide();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Bottom progress bar.
          if (_bytes != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _SlideIn(
                visible: _chrome,
                fromTop: false,
                child: Listener(
                  onPointerDown: (_) => _keepChrome(),
                  child: Material(
                    color: chromeColor,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 6,
                                  color: style.chromeForeground,
                                  backgroundColor: style.chromeForeground.withValues(alpha: 0.15),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              total > 0 ? '$page / $total  ·  ${(progress * 100).round()}%' : '$page',
                              style: TextStyle(
                                color: style.chromeForeground,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Thin always-visible progress hairline when the chrome is hidden.
          if (_bytes != null && !_chrome && total > 0)
            Align(
              alignment: Alignment.bottomCenter,
              child: IgnorePointer(
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 2,
                  color: style.chromeForeground.withValues(alpha: 0.6),
                  backgroundColor: Colors.transparent,
                ),
              ),
            ),
        ],
        ),
      ),
    );
  }

  /// On the web the page is a canvas, so the browser never scrolls it. Arrow
  /// keys move the reading position instead. Mobile keeps using touch.
  Widget _arrowKeys(Widget child) {
    if (!kIsWeb) return child;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): _ArrowIntent(1),
        SingleActivator(LogicalKeyboardKey.arrowUp): _ArrowIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowRight): _ArrowIntent(1),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _ArrowIntent(-1),
      },
      child: Actions(
        actions: {
          _ArrowIntent: CallbackAction<_ArrowIntent>(
            onInvoke: (intent) {
              _scrollByArrow(intent.direction);
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _ArrowIntent extends Intent {
  const _ArrowIntent(this.direction);
  final int direction;
}

/// Slides a bar in from the top or bottom edge and fades it.
class _SlideIn extends StatelessWidget {
  const _SlideIn({required this.visible, required this.fromTop, required this.child});
  final bool visible;
  final bool fromTop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : Offset(0, fromTop ? -1 : 1),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: visible ? 1 : 0,
          child: child,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
