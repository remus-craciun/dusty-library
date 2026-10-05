import '../../data/models.dart';

/// Whether [book] matches a library search. An empty query matches everything.
bool bookMatchesQuery(Book book, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return book.title.toLowerCase().contains(q) ||
      book.author.toLowerCase().contains(q);
}

/// The book most recently opened, or null when nothing on the shelf has been read.
///
/// [books] may be in any order; the latest [Book.lastReadAt] wins.
Book? continueReading(Iterable<Book> books) {
  Book? best;
  for (final book in books) {
    final at = book.lastReadAt;
    if (at == null) continue;
    final bestAt = best?.lastReadAt;
    if (bestAt == null || at.isAfter(bestAt)) best = book;
  }
  return best;
}
