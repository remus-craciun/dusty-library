import 'dart:ui';

/// Which part of the screen a tap landed in. The outer [edgeFraction] on each
/// side turns the page; the middle shows the reader bars.
enum TapZone { previous, next, center }

TapZone tapZone(double x, double width, {double edgeFraction = 0.2}) {
  if (width <= 0) return TapZone.center;
  final fraction = x / width;
  if (fraction <= edgeFraction) return TapZone.previous;
  if (fraction >= 1 - edgeFraction) return TapZone.next;
  return TapZone.center;
}

/// Where the top of the screen sits in a book: a 1-based [page] and how far
/// down that full page, from 0 (top) to 1 (bottom).
class ReadingSpot {
  const ReadingSpot(this.page, this.offset);
  final int page;
  final double offset;
}

/// A page laid out in one vertical coordinate space (PDF points, or pixels).
class PageSpan {
  const PageSpan(this.top, this.height);
  final double top;
  final double height;
}

/// The page under [viewportTop], and the fraction of that page above it.
///
/// [pages] are tops and heights in the same coordinates as [viewportTop],
/// top to bottom. A position above the first page is the top of page 1; past
/// the last page is the bottom of the last page.
ReadingSpot readingSpot({required double viewportTop, required List<PageSpan> pages}) {
  if (pages.isEmpty) return const ReadingSpot(1, 0);
  var index = pages.length - 1;
  for (var i = 0; i < pages.length; i++) {
    if (viewportTop < pages[i].top + pages[i].height) {
      index = i;
      break;
    }
  }
  final page = pages[index];
  final raw = page.height <= 0 ? 0.0 : (viewportTop - page.top) / page.height;
  return ReadingSpot(index + 1, raw.clamp(0.0, 1.0).toDouble());
}

/// One focus-mode page: the on-screen strip plus the crop inside the full PDF
/// page, both measured from the top.
class FocusPage {
  const FocusPage({
    required this.viewTop,
    required this.viewHeight,
    required this.cropTop,
    required this.cropHeight,
    required this.pageHeight,
  });

  final double viewTop;
  final double viewHeight;
  final double cropTop;
  final double cropHeight;
  final double pageHeight;
}

/// Focus mode shows a crop of each page stretched to the screen. [scrollTop]
/// is the viewport top in that view; the result is the same full-page spot
/// the normal reader stores.
ReadingSpot focusReadingSpot({required double scrollTop, required List<FocusPage> pages}) {
  if (pages.isEmpty) return const ReadingSpot(1, 0);
  var index = pages.length - 1;
  for (var i = 0; i < pages.length; i++) {
    if (scrollTop < pages[i].viewTop + pages[i].viewHeight) {
      index = i;
      break;
    }
  }
  final page = pages[index];
  final alongCrop = page.viewHeight <= 0 ? 0.0 : (scrollTop - page.viewTop) / page.viewHeight;
  final pdfY = page.cropTop + alongCrop.clamp(0.0, 1.0) * page.cropHeight;
  final offset = page.pageHeight <= 0 ? 0.0 : pdfY / page.pageHeight;
  return ReadingSpot(index + 1, offset.clamp(0.0, 1.0).toDouble());
}

/// Scroll offset in the focus view that puts [spot] at the top of the screen.
/// Parts of the page outside its crop are not shown, so the result stays
/// inside the cropped strip.
double focusScrollOffset({required ReadingSpot spot, required List<FocusPage> pages}) {
  if (pages.isEmpty) return 0;
  final index = (spot.page - 1).clamp(0, pages.length - 1);
  final page = pages[index];
  final pdfY = spot.offset.clamp(0.0, 1.0) * page.pageHeight;
  final alongCrop = page.cropHeight <= 0 ? 0.0 : (pdfY - page.cropTop) / page.cropHeight;
  return page.viewTop + alongCrop.clamp(0.0, 1.0) * page.viewHeight;
}

/// Builds focus pages from the cropped rectangles and the on-screen layout.
List<FocusPage> focusPages({
  required List<Rect> crops,
  required List<double> pageHeights,
  required List<double> viewTops,
  required List<double> viewHeights,
}) {
  return [
    for (var i = 0; i < crops.length; i++)
      FocusPage(
        viewTop: viewTops[i],
        viewHeight: viewHeights[i],
        cropTop: crops[i].top,
        cropHeight: crops[i].height,
        pageHeight: pageHeights[i],
      ),
  ];
}
