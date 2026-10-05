import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/api_client.dart';
import '../../data/library_repository.dart';
import '../../data/models.dart';
import 'upload_dialog.dart';

/// Shelf selection in the library screen. [id] `null` means all books. Until
/// the user picks something ([explicit] is false) the screen shows the
/// predefined `Active` shelf, whose id is only known once the library loads.
typedef ShelfSelection = ({int? id, bool explicit});

class SelectedShelf extends Notifier<ShelfSelection> {
  @override
  ShelfSelection build() => (id: null, explicit: false);
  void select(int? id) => state = (id: id, explicit: true);
}

final selectedShelfProvider = NotifierProvider<SelectedShelf, ShelfSelection>(SelectedShelf.new);

/// Source of truth for shelves and books in the UI.
class LibraryNotifier extends AsyncNotifier<LibraryData> {
  LibraryRepository get _repo => ref.read(libraryRepositoryProvider);

  @override
  Future<LibraryData> build() {
    ref.watch(libraryRepositoryProvider);
    return _repo.load();
  }

  /// Reloads from the server, keeping the current data visible meanwhile.
  Future<void> refresh() async {
    final previous = state.asData?.value;
    try {
      state = AsyncData(await _repo.load());
    } on NetworkException {
      if (previous != null) {
        state = AsyncData(previous.copyWith(offline: true));
      } else {
        rethrow;
      }
    }
  }

  void _patch(LibraryData Function(LibraryData d) f) {
    final cur = state.asData?.value;
    if (cur != null) state = AsyncData(f(cur));
  }

  void _replaceBook(Book book) =>
      _patch((d) => d.copyWith(books: d.books.map((b) => b.id == book.id ? book : b).toList()));

  // --- shelves -------------------------------------------------------------

  Future<void> createShelf(String name) async {
    final shelf = await _repo.api.createShelf(name);
    _patch((d) => d.copyWith(shelves: [...d.shelves, shelf]));
  }

  Future<void> renameShelf(int id, String name) async {
    final shelf = await _repo.api.renameShelf(id, name);
    _patch((d) => d.copyWith(shelves: d.shelves.map((s) => s.id == id ? shelf : s).toList()));
  }

  Future<void> deleteShelf(int id) async {
    await _repo.api.deleteShelf(id);
    if (ref.read(selectedShelfProvider).id == id) {
      ref.read(selectedShelfProvider.notifier).select(null);
    }
    await refresh();
  }

  // --- books ---------------------------------------------------------------

  Future<void> moveBook(Book book, int shelfId) async {
    _replaceBook(book.copyWith(shelfId: shelfId));
    try {
      _replaceBook(await _repo.api.patchBook(book.id, shelfId: shelfId));
    } catch (_) {
      _replaceBook(book);
      rethrow;
    }
  }

  Future<void> renameBook(Book book, String title, String author) async {
    _replaceBook(await _repo.api.patchBook(book.id, title: title, author: author));
  }

  Future<void> setPageCount(Book book, int pageCount) async {
    if (book.pageCount == pageCount) return;
    _replaceBook(book.copyWith(pageCount: pageCount));
    try {
      _replaceBook(await _repo.api.patchBook(book.id, pageCount: pageCount));
    } on NetworkException {
      // Will be fixed up on the next successful open.
    }
  }

  Future<void> deleteBook(Book book) async {
    await _repo.deleteBook(book.id);
    _patch(
      (d) => d.copyWith(
        books: d.books.where((b) => b.id != book.id).toList(),
        downloaded: {...d.downloaded}..remove(book.id),
      ),
    );
  }

  /// Uploads a PDF. The page count is computed on the device so the server
  /// never has to parse PDFs. [progress] is updated as the stages advance.
  Future<Book> upload({
    required String filename,
    required Uint8List bytes,
    String? title,
    String author = '',
    int? shelfId,
    UploadProgress? progress,
  }) async {
    progress?.setStage(UploadStage.counting);
    var pageCount = 0;
    try {
      final doc = await PdfDocument.openData(bytes, sourceName: filename);
      pageCount = doc.pages.length;
      await doc.dispose();
    } catch (_) {
      // Unreadable locally; the reader will report the count once it opens.
    }
    final cleanTitle = (title ?? '').trim();
    progress?.setStage(UploadStage.uploading);
    final book = await _repo.api.uploadBook(
      filename: filename,
      bytes: bytes,
      title: cleanTitle.isEmpty ? titleFromFilename(filename) : cleanTitle,
      author: author.trim(),
      pageCount: pageCount,
      shelfId: shelfId,
      onProgress: progress?.setFraction,
    );
    progress?.setStage(UploadStage.processing);
    // Keep the freshly uploaded bytes so it can be read offline immediately.
    await _repo.cache.writeBook(book.id, bytes);
    _patch((d) => d.copyWith(books: [book, ...d.books], downloaded: {...d.downloaded, book.id}));
    return book;
  }

  /// Applies progress reported by the reader (local-first, queued if offline).
  Future<Book> saveProgress(Book book, int page, double pageOffset) async {
    final latest = state.asData?.value.book(book.id) ?? book;
    final updated = await _repo.saveProgress(latest, page, pageOffset);
    _replaceBook(updated);
    return updated;
  }

  // --- offline copies ------------------------------------------------------

  Future<void> download(Book book, {void Function(double)? onProgress}) async {
    await _repo.download(book.id, onProgress: onProgress);
    _patch((d) => d.copyWith(downloaded: {...d.downloaded, book.id}));
  }

  Future<void> removeDownload(Book book) async {
    await _repo.removeDownload(book.id);
    _patch((d) => d.copyWith(downloaded: {...d.downloaded}..remove(book.id)));
  }

  void markDownloaded(int id) => _patch((d) => d.copyWith(downloaded: {...d.downloaded, id}));
}

final libraryProvider = AsyncNotifierProvider<LibraryNotifier, LibraryData>(LibraryNotifier.new);

/// Turns `the_dusty-shelf.pdf` into `the dusty shelf`.
String titleFromFilename(String name) {
  var t = name;
  final dot = t.lastIndexOf('.');
  if (dot > 0) t = t.substring(0, dot);
  return t.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
}
