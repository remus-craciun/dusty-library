/// Plain data models mirroring the server's JSON API.
library;

enum ShelfKind {
  active,
  completed,
  custom;

  static ShelfKind parse(String v) => switch (v) {
    'active' => ShelfKind.active,
    'completed' => ShelfKind.completed,
    _ => ShelfKind.custom,
  };
}

class Shelf {
  const Shelf({
    required this.id,
    required this.name,
    required this.kind,
    required this.sortOrder,
  });

  final int id;
  final String name;
  final ShelfKind kind;
  final int sortOrder;

  bool get isPredefined => kind != ShelfKind.custom;

  factory Shelf.fromJson(Map<String, dynamic> j) => Shelf(
    id: j['id'] as int,
    name: j['name'] as String,
    kind: ShelfKind.parse(j['kind'] as String),
    sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'sort_order': sortOrder,
  };

  Shelf copyWith({String? name}) =>
      Shelf(id: id, name: name ?? this.name, kind: kind, sortOrder: sortOrder);
}

class Book {
  const Book({
    required this.id,
    required this.shelfId,
    required this.title,
    required this.author,
    required this.filename,
    required this.sizeBytes,
    required this.pageCount,
    required this.currentPage,
    this.pageOffset = 0,
    this.progressUpdatedAt,
    this.lastReadAt,
    required this.createdAt,
  });

  final int id;
  final int shelfId;
  final String title;
  final String author;
  final String filename;
  final int sizeBytes;
  final int pageCount;
  final int currentPage;

  /// How far down [currentPage] the viewport top was, from 0 (top) to 1 (bottom).
  final double pageOffset;
  final DateTime? progressUpdatedAt;
  final DateTime? lastReadAt;
  final DateTime createdAt;

  /// Fraction read in 0..1. Zero when the page count is unknown.
  double get progress =>
      pageCount <= 0 ? 0 : (currentPage / pageCount).clamp(0, 1).toDouble();

  bool get isFinished => pageCount > 0 && currentPage >= pageCount;

  factory Book.fromJson(Map<String, dynamic> j) => Book(
    id: j['id'] as int,
    shelfId: j['shelf_id'] as int,
    title: j['title'] as String,
    author: (j['author'] as String?) ?? '',
    filename: (j['filename'] as String?) ?? '',
    sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
    pageCount: (j['page_count'] as num?)?.toInt() ?? 0,
    currentPage: (j['current_page'] as num?)?.toInt() ?? 0,
    pageOffset: ((j['page_offset'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0).toDouble(),
    progressUpdatedAt: _date(j['progress_updated_at']),
    lastReadAt: _date(j['last_read_at']),
    createdAt: _date(j['created_at']) ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'shelf_id': shelfId,
    'title': title,
    'author': author,
    'filename': filename,
    'size_bytes': sizeBytes,
    'page_count': pageCount,
    'current_page': currentPage,
    'page_offset': pageOffset,
    'progress_updated_at': progressUpdatedAt?.toUtc().toIso8601String(),
    'last_read_at': lastReadAt?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  Book copyWith({
    int? shelfId,
    String? title,
    String? author,
    int? pageCount,
    int? currentPage,
    double? pageOffset,
    DateTime? progressUpdatedAt,
    DateTime? lastReadAt,
  }) => Book(
    id: id,
    shelfId: shelfId ?? this.shelfId,
    title: title ?? this.title,
    author: author ?? this.author,
    filename: filename,
    sizeBytes: sizeBytes,
    pageCount: pageCount ?? this.pageCount,
    currentPage: currentPage ?? this.currentPage,
    pageOffset: pageOffset ?? this.pageOffset,
    progressUpdatedAt: progressUpdatedAt ?? this.progressUpdatedAt,
    lastReadAt: lastReadAt ?? this.lastReadAt,
    createdAt: createdAt,
  );
}

/// Page filters applied over the rendered PDF to make reading easier on the eyes.
enum PageFilter {
  none('none', 'Plain'),
  paper('paper', 'Old paper'),
  sepia('sepia', 'Sepia'),
  dark('dark', 'Dark');

  const PageFilter(this.wire, this.label);
  final String wire;
  final String label;

  static PageFilter parse(String? v) =>
      PageFilter.values.firstWhere((f) => f.wire == v, orElse: () => none);
}

class ReaderSettings {
  const ReaderSettings({this.zoom = 1.0, this.filter = PageFilter.none});

  /// Relative zoom on top of "fit width"; acts as the font size control.
  final double zoom;
  final PageFilter filter;

  static const minZoom = 0.75;
  static const maxZoom = 3.0;

  factory ReaderSettings.fromJson(Map<String, dynamic> j) => ReaderSettings(
    zoom: ((j['zoom'] as num?)?.toDouble() ?? 1.0).clamp(minZoom, maxZoom),
    filter: PageFilter.parse(j['filter'] as String?),
  );

  Map<String, dynamic> toJson() => {'zoom': zoom, 'filter': filter.wire};

  ReaderSettings copyWith({double? zoom, PageFilter? filter}) =>
      ReaderSettings(zoom: zoom ?? this.zoom, filter: filter ?? this.filter);
}

class ServerStatus {
  const ServerStatus({required this.registered, required this.name});
  final bool registered;
  final String name;

  factory ServerStatus.fromJson(Map<String, dynamic> j) => ServerStatus(
    registered: j['registered'] == true,
    name: (j['name'] as String?) ?? '',
  );
}

class AuthResult {
  const AuthResult({required this.token, required this.username});
  final String token;
  final String username;

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
    token: j['token'] as String,
    username: (j['user'] as Map<String, dynamic>)['username'] as String,
  );
}

/// A progress report waiting to be pushed to the server.
class PendingProgress {
  const PendingProgress({
    required this.bookId,
    required this.page,
    required this.at,
    this.pageOffset = 0,
  });
  final int bookId;
  final int page;
  final DateTime at;
  final double pageOffset;

  factory PendingProgress.fromJson(Map<String, dynamic> j) => PendingProgress(
    bookId: j['book_id'] as int,
    page: j['page'] as int,
    at: DateTime.parse(j['at'] as String),
    pageOffset: ((j['page_offset'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'book_id': bookId,
    'page': page,
    'page_offset': pageOffset,
    'at': at.toUtc().toIso8601String(),
  };
}

DateTime? _date(Object? v) =>
    v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;
