import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import 'local_cache.dart';
import 'models.dart';

/// Everything the library screen needs, with offline metadata.
class LibraryData {
  const LibraryData({
    required this.shelves,
    required this.books,
    required this.downloaded,
    required this.offline,
    this.pendingCount = 0,
    this.cachedAt,
  });

  final List<Shelf> shelves;
  final List<Book> books;

  /// Ids of books whose PDF is stored on this device.
  final Set<int> downloaded;

  /// True when this data came from the local cache because the server was
  /// unreachable.
  final bool offline;

  /// Number of progress updates still waiting to be pushed.
  final int pendingCount;
  final DateTime? cachedAt;

  Shelf? shelfOfKind(ShelfKind kind) {
    for (final s in shelves) {
      if (s.kind == kind) return s;
    }
    return null;
  }

  Book? book(int id) {
    for (final b in books) {
      if (b.id == id) return b;
    }
    return null;
  }

  List<Book> booksOn(int? shelfId) =>
      shelfId == null ? books : books.where((b) => b.shelfId == shelfId).toList();

  LibraryData copyWith({
    List<Shelf>? shelves,
    List<Book>? books,
    Set<int>? downloaded,
    bool? offline,
    int? pendingCount,
    DateTime? cachedAt,
  }) => LibraryData(
    shelves: shelves ?? this.shelves,
    books: books ?? this.books,
    downloaded: downloaded ?? this.downloaded,
    offline: offline ?? this.offline,
    pendingCount: pendingCount ?? this.pendingCount,
    cachedAt: cachedAt ?? this.cachedAt,
  );
}

/// Remote-first repository with a local fallback. All reads try the server and
/// persist the result; when the server is unreachable the cached snapshot is
/// returned flagged as offline. Progress writes are applied locally first and
/// queued when they cannot be delivered.
class LibraryRepository {
  LibraryRepository(this.api, this.cache);

  final ApiClient api;
  final LocalCache cache;

  Future<LibraryData> load() async {
    final downloaded = await cache.downloadedBookIds();
    try {
      // Probe the server and drain the offline queue together: when the
      // device is offline both fail fast on the same short timeout instead of
      // one after the other.
      final results = await Future.wait([api.listShelves(), api.listBooks(), syncPending()]);
      final shelves = results[0] as List<Shelf>;
      final books = results[1] as List<Book>;
      // Books deleted on the server should not linger on disk.
      for (final id in downloaded.toList()) {
        if (!books.any((b) => b.id == id)) {
          await cache.deleteBook(id);
          downloaded.remove(id);
        }
      }
      await cache.writeLibrary(
        LibrarySnapshot(shelves: shelves, books: books, savedAt: DateTime.now()),
      );
      return LibraryData(
        shelves: shelves,
        books: books,
        downloaded: downloaded,
        offline: false,
      );
    } on NetworkException {
      final snap = await cache.readLibrary();
      if (snap == null) rethrow;
      final pending = await cache.readPending();
      return LibraryData(
        shelves: snap.shelves,
        books: _applyPending(snap.books, pending),
        downloaded: downloaded,
        offline: true,
        pendingCount: pending.length,
        cachedAt: snap.savedAt,
      );
    }
  }

  /// Overlays queued progress so the UI reflects local reading even offline.
  List<Book> _applyPending(List<Book> books, List<PendingProgress> pending) {
    if (pending.isEmpty) return books;
    final latest = <int, PendingProgress>{};
    for (final p in pending) {
      final cur = latest[p.bookId];
      if (cur == null || p.at.isAfter(cur.at)) latest[p.bookId] = p;
    }
    return books.map((b) {
      final p = latest[b.id];
      if (p == null) return b;
      final newer = b.progressUpdatedAt == null || p.at.isAfter(b.progressUpdatedAt!);
      return newer
          ? b.copyWith(currentPage: p.page, pageOffset: p.pageOffset, progressUpdatedAt: p.at, lastReadAt: p.at)
          : b;
    }).toList();
  }

  /// Pushes queued progress updates. Stops at the first network failure and
  /// keeps the remainder queued. Returns the number delivered.
  Future<int> syncPending() async {
    final pending = await cache.readPending();
    if (pending.isEmpty) return 0;
    var sent = 0;
    final remaining = List.of(pending);
    for (final p in pending) {
      try {
        await api.putProgress(p.bookId, p.page, p.pageOffset, p.at);
      } on ApiException catch (e) {
        if (e.status != 404) rethrow; // book deleted elsewhere: drop it
      } on NetworkException {
        break;
      }
      remaining.remove(p);
      sent++;
    }
    await cache.writePending(remaining);
    return sent;
  }

  /// Records progress locally and tries to deliver it. Returns the book with
  /// the new progress applied.
  Future<Book> saveProgress(Book book, int page, double pageOffset) async {
    final at = DateTime.now();
    final offset = pageOffset.clamp(0.0, 1.0).toDouble();
    final updated = book.copyWith(currentPage: page, pageOffset: offset, progressUpdatedAt: at, lastReadAt: at);
    await _updateCachedBook(updated);
    try {
      final remote = await api.putProgress(book.id, page, offset, at);
      await _updateCachedBook(remote);
      return remote;
    } on NetworkException {
      final pending = await cache.readPending();
      pending.removeWhere((p) => p.bookId == book.id);
      pending.add(PendingProgress(bookId: book.id, page: page, pageOffset: offset, at: at));
      await cache.writePending(pending);
      return updated;
    }
  }

  Future<void> _updateCachedBook(Book book) async {
    final snap = await cache.readLibrary();
    if (snap == null) return;
    final books = snap.books.map((b) => b.id == book.id ? book : b).toList();
    await cache.writeLibrary(LibrarySnapshot(shelves: snap.shelves, books: books, savedAt: snap.savedAt));
  }

  /// Returns the PDF bytes, downloading and caching them on first access.
  Future<Uint8List> openBook(int id, {void Function(double)? onProgress}) async {
    final local = await cache.readBook(id);
    if (local != null) return local;
    final bytes = await api.downloadBook(id, onProgress: onProgress);
    await cache.writeBook(id, bytes);
    return bytes;
  }

  Future<void> download(int id, {void Function(double)? onProgress}) async {
    if (await cache.hasBook(id)) return;
    final bytes = await api.downloadBook(id, onProgress: onProgress);
    await cache.writeBook(id, bytes);
  }

  Future<void> removeDownload(int id) => cache.deleteBook(id);

  Future<void> deleteBook(int id) async {
    await api.deleteBook(id);
    await cache.deleteBook(id);
  }
}

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(ref.watch(apiClientProvider), ref.watch(localCacheProvider)),
);
