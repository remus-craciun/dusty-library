import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

/// One place a query was found in a PDF.
class FindHit {
  const FindHit({required this.pageNumber, required this.bounds});

  final int pageNumber;
  final PdfRect bounds;
}

/// Searches a PDF's text and keeps the hits so the reader can step through them.
///
/// The search walks pages as they are read and notifies after each page, so the
/// first hit can be shown before the rest of a long book is scanned.
class BookFind extends ChangeNotifier {
  int _generation = 0;
  String query = '';
  List<FindHit> hits = const [];
  int index = -1;
  bool searching = false;
  int searchedPages = 0;
  int totalPages = 0;

  FindHit? get current =>
      index >= 0 && index < hits.length ? hits[index] : null;

  /// Starts a case-insensitive search. A newer call cancels the one in progress.
  Future<void> start(Uint8List bytes, String raw) async {
    final q = raw.trim();
    final generation = ++_generation;
    query = q;
    hits = const [];
    index = -1;
    searchedPages = 0;
    totalPages = 0;
    if (q.isEmpty) {
      searching = false;
      notifyListeners();
      return;
    }
    searching = true;
    notifyListeners();

    PdfDocument? doc;
    try {
      doc = await PdfDocument.openData(bytes, sourceName: 'find-$generation');
      if (generation != _generation) return;
      totalPages = doc.pages.length;
      final found = <FindHit>[];
      for (final page in doc.pages) {
        if (generation != _generation) return;
        final text = await page.loadStructuredText();
        if (generation != _generation) return;
        await for (final match in text.allMatches(q, caseInsensitive: true)) {
          if (generation != _generation) return;
          final bounds = match.bounds;
          if (bounds.isEmpty) continue;
          found.add(FindHit(pageNumber: match.pageNumber, bounds: bounds));
        }
        searchedPages = page.pageNumber;
        hits = List.unmodifiable(found);
        if (index < 0 && hits.isNotEmpty) index = 0;
        notifyListeners();
      }
    } finally {
      await doc?.dispose();
      if (generation == _generation) {
        searching = false;
        notifyListeners();
      }
    }
  }

  void clear() {
    _generation++;
    query = '';
    hits = const [];
    index = -1;
    searching = false;
    searchedPages = 0;
    totalPages = 0;
    notifyListeners();
  }

  /// Moves to the next hit. Returns it, or null when there is nowhere to go.
  FindHit? next() => _step(1);

  /// Moves to the previous hit.
  FindHit? previous() => _step(-1);

  FindHit? _step(int direction) {
    if (hits.isEmpty) return null;
    if (index < 0) {
      index = direction < 0 ? hits.length - 1 : 0;
    } else {
      final nextIndex = index + direction;
      if (nextIndex < 0 || nextIndex >= hits.length) return current;
      index = nextIndex;
    }
    notifyListeners();
    return current;
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }
}
