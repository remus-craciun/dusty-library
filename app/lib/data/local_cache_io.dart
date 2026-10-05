import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'local_cache.dart';
import 'models.dart';

Future<LocalCache> openCache() async {
  final docs = await getApplicationDocumentsDirectory();
  final root = Directory('${docs.path}${Platform.pathSeparator}dusty');
  await root.create(recursive: true);
  await Directory('${root.path}${Platform.pathSeparator}books').create();
  return FileCache(root);
}

/// File based cache stored under the app documents directory (mobile/desktop).
class FileCache implements LocalCache {
  FileCache(this.root);

  final Directory root;

  File get _library => File('${root.path}/library.json');
  File get _settings => File('${root.path}/settings.json');
  File get _pending => File('${root.path}/pending_progress.json');
  Directory get _books => Directory('${root.path}/books');
  File bookFile(int id) => File('${_books.path}/$id.pdf');

  @override
  bool get persistsFiles => true;

  Future<Map<String, dynamic>?> _readJson(File f) async {
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJson(File f, Object value) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<LibrarySnapshot?> readLibrary() async {
    final j = await _readJson(_library);
    return j == null ? null : LibrarySnapshot.fromJson(j);
  }

  @override
  Future<void> writeLibrary(LibrarySnapshot snapshot) =>
      _writeJson(_library, snapshot.toJson());

  @override
  Future<ReaderSettings?> readSettings() async {
    final j = await _readJson(_settings);
    return j == null ? null : ReaderSettings.fromJson(j);
  }

  @override
  Future<void> writeSettings(ReaderSettings settings) =>
      _writeJson(_settings, settings.toJson());

  @override
  Future<bool> hasBook(int id) => bookFile(id).exists();

  @override
  Future<Uint8List?> readBook(int id) async {
    final f = bookFile(id);
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> writeBook(int id, Uint8List bytes) async {
    await _books.create(recursive: true);
    final tmp = File('${bookFile(id).path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(bookFile(id).path);
  }

  @override
  Future<void> deleteBook(int id) async {
    final f = bookFile(id);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<Set<int>> downloadedBookIds() async {
    if (!await _books.exists()) return {};
    final ids = <int>{};
    await for (final e in _books.list()) {
      final name = e.uri.pathSegments.last;
      if (!name.endsWith('.pdf')) continue;
      final id = int.tryParse(name.substring(0, name.length - 4));
      if (id != null) ids.add(id);
    }
    return ids;
  }

  @override
  Future<List<PendingProgress>> readPending() async {
    final j = await _readJson(_pending);
    if (j == null) return [];
    return (j['items'] as List)
        .cast<Map<String, dynamic>>()
        .map(PendingProgress.fromJson)
        .toList();
  }

  @override
  Future<void> writePending(List<PendingProgress> items) => _writeJson(
    _pending,
    {'items': items.map((p) => p.toJson()).toList()},
  );

  @override
  Future<void> clear() async {
    if (await root.exists()) await root.delete(recursive: true);
    await _books.create(recursive: true);
  }
}
