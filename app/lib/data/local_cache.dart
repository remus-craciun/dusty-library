import 'dart:typed_data';

import 'models.dart';

import 'local_cache_memory.dart'
    if (dart.library.io) 'local_cache_io.dart'
    as impl;

/// Snapshot of the library persisted for offline use.
class LibrarySnapshot {
  const LibrarySnapshot({
    required this.shelves,
    required this.books,
    required this.savedAt,
  });
  final List<Shelf> shelves;
  final List<Book> books;
  final DateTime savedAt;

  factory LibrarySnapshot.fromJson(Map<String, dynamic> j) => LibrarySnapshot(
    shelves: (j['shelves'] as List)
        .cast<Map<String, dynamic>>()
        .map(Shelf.fromJson)
        .toList(),
    books: (j['books'] as List)
        .cast<Map<String, dynamic>>()
        .map(Book.fromJson)
        .toList(),
    savedAt: DateTime.parse(j['saved_at'] as String),
  );

  Map<String, dynamic> toJson() => {
    'shelves': shelves.map((s) => s.toJson()).toList(),
    'books': books.map((b) => b.toJson()).toList(),
    'saved_at': savedAt.toUtc().toIso8601String(),
  };
}

/// Device-side storage for metadata, settings, downloaded PDFs and the queue of
/// progress updates that could not be sent yet.
///
/// On mobile this is backed by files in the app documents directory; on web it
/// is an in-memory cache that only lives for the current session.
abstract class LocalCache {
  /// Creates the platform-appropriate implementation.
  static Future<LocalCache> open() => impl.openCache();

  /// Whether PDFs survive app restarts on this platform.
  bool get persistsFiles;

  Future<LibrarySnapshot?> readLibrary();
  Future<void> writeLibrary(LibrarySnapshot snapshot);

  Future<ReaderSettings?> readSettings();
  Future<void> writeSettings(ReaderSettings settings);

  Future<bool> hasBook(int id);
  Future<Uint8List?> readBook(int id);
  Future<void> writeBook(int id, Uint8List bytes);
  Future<void> deleteBook(int id);
  Future<Set<int>> downloadedBookIds();

  Future<List<PendingProgress>> readPending();
  Future<void> writePending(List<PendingProgress> items);

  /// Removes everything (used on logout / server change).
  Future<void> clear();
}
