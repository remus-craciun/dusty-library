import 'dart:typed_data';

import 'local_cache.dart';
import 'models.dart';

Future<LocalCache> openCache() async => MemoryCache();

/// Session-only cache used on the web where there is no file system access.
class MemoryCache implements LocalCache {
  LibrarySnapshot? _library;
  ReaderSettings? _settings;
  final Map<int, Uint8List> _books = {};
  List<PendingProgress> _pending = [];

  @override
  bool get persistsFiles => false;

  @override
  Future<LibrarySnapshot?> readLibrary() async => _library;

  @override
  Future<void> writeLibrary(LibrarySnapshot snapshot) async =>
      _library = snapshot;

  @override
  Future<ReaderSettings?> readSettings() async => _settings;

  @override
  Future<void> writeSettings(ReaderSettings settings) async =>
      _settings = settings;

  @override
  Future<bool> hasBook(int id) async => _books.containsKey(id);

  @override
  Future<Uint8List?> readBook(int id) async => _books[id];

  @override
  Future<void> writeBook(int id, Uint8List bytes) async => _books[id] = bytes;

  @override
  Future<void> deleteBook(int id) async => _books.remove(id);

  @override
  Future<Set<int>> downloadedBookIds() async => _books.keys.toSet();

  @override
  Future<List<PendingProgress>> readPending() async => List.of(_pending);

  @override
  Future<void> writePending(List<PendingProgress> items) async =>
      _pending = List.of(items);

  @override
  Future<void> clear() async {
    _library = null;
    _settings = null;
    _books.clear();
    _pending = [];
  }
}
