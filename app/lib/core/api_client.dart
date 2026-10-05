import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../data/models.dart';

/// The server answered with a non-2xx status.
class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;

  bool get isUnauthorized => status == 401;

  @override
  String toString() => 'ApiException($status): $message';
}

/// The server could not be reached at all (offline, wrong address, timeout).
class NetworkException implements Exception {
  NetworkException(this.message);
  final String message;

  @override
  String toString() => 'NetworkException: $message';
}

typedef TokenProvider = String? Function();
typedef UnauthorizedHandler = void Function();

/// Thin typed wrapper over the Dusty Library HTTP API.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required TokenProvider token,
    UnauthorizedHandler? onUnauthorized,
    http.Client? client,
  }) : _token = token,
       _onUnauthorized = onUnauthorized,
       _client = client ?? http.Client();

  // ignore_for_file: prefer_initializing_formals

  /// Server origin without trailing slash, e.g. `http://192.168.1.10:8080`.
  final String baseUrl;
  final TokenProvider _token;
  final UnauthorizedHandler? _onUnauthorized;
  final http.Client _client;

  /// How long to wait for the server to accept the connection and start
  /// answering. Short on purpose: when the device is offline or the server is
  /// down the app falls back to its cache, and a long hang defeats that.
  static const _connectTimeout = Duration(seconds: 4);

  /// How long a request that is already transferring data may run. Downloads
  /// and uploads of large PDFs need far more than the connect budget.
  static const _transferTimeout = Duration(minutes: 10);

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Map<String, String> _headers({bool json = true}) {
    final h = <String, String>{'Accept': 'application/json'};
    if (json) h['Content-Type'] = 'application/json';
    final t = _token();
    if (t != null && t.isNotEmpty) h['Authorization'] = 'Bearer $t';
    return h;
  }

  Future<http.Response> _send(
    Future<http.Response> Function() f, {
    Duration timeout = _connectTimeout,
  }) async {
    http.Response res;
    try {
      res = await f().timeout(timeout);
    } on http.ClientException catch (e) {
      throw NetworkException(e.message);
    } on TimeoutException {
      throw NetworkException('Request timed out');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    if (res.statusCode == 401) _onUnauthorized?.call();
    throw ApiException(res.statusCode, _errorMessage(res));
  }

  String _errorMessage(http.Response res) {
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Map && body['error'] is String) return body['error'] as String;
    } catch (_) {}
    return 'HTTP ${res.statusCode}';
  }

  dynamic _json(http.Response res) =>
      res.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));

  Future<dynamic> _get(String path, [Map<String, String>? q]) async =>
      _json(await _send(() => _client.get(_uri(path, q), headers: _headers())));

  Future<dynamic> _post(String path, Object body) async => _json(
    await _send(
      () => _client.post(
        _uri(path),
        headers: _headers(),
        body: jsonEncode(body),
      ),
    ),
  );

  Future<dynamic> _put(String path, Object body) async => _json(
    await _send(
      () => _client.put(
        _uri(path),
        headers: _headers(),
        body: jsonEncode(body),
      ),
    ),
  );

  Future<dynamic> _patch(String path, Object body) async => _json(
    await _send(
      () => _client.patch(
        _uri(path),
        headers: _headers(),
        body: jsonEncode(body),
      ),
    ),
  );

  Future<void> _delete(String path) async =>
      _send(() => _client.delete(_uri(path), headers: _headers()));

  // --- status & auth -------------------------------------------------------

  Future<ServerStatus> status() async =>
      ServerStatus.fromJson(await _get('/api/status') as Map<String, dynamic>);

  Future<AuthResult> register(String username, String password) async =>
      AuthResult.fromJson(
        await _post('/api/auth/register', {
              'username': username,
              'password': password,
            })
            as Map<String, dynamic>,
      );

  Future<AuthResult> login(String username, String password) async =>
      AuthResult.fromJson(
        await _post('/api/auth/login', {
              'username': username,
              'password': password,
            })
            as Map<String, dynamic>,
      );

  /// Revokes the current token on the server.
  Future<void> logout() async =>
      _send(() => _client.post(_uri('/api/auth/logout'), headers: _headers()));

  /// Revokes every token of the account (all devices).
  Future<void> logoutAll() async =>
      _send(() => _client.post(_uri('/api/auth/logout-all'), headers: _headers()));

  // --- settings ------------------------------------------------------------

  Future<ReaderSettings> getSettings() async => ReaderSettings.fromJson(
    await _get('/api/settings') as Map<String, dynamic>,
  );

  Future<ReaderSettings> putSettings(ReaderSettings s) async =>
      ReaderSettings.fromJson(
        await _put('/api/settings', s.toJson()) as Map<String, dynamic>,
      );

  // --- shelves -------------------------------------------------------------

  Future<List<Shelf>> listShelves() async => (await _get('/api/shelves') as List)
      .cast<Map<String, dynamic>>()
      .map(Shelf.fromJson)
      .toList();

  Future<Shelf> createShelf(String name) async => Shelf.fromJson(
    await _post('/api/shelves', {'name': name}) as Map<String, dynamic>,
  );

  Future<Shelf> renameShelf(int id, String name) async => Shelf.fromJson(
    await _patch('/api/shelves/$id', {'name': name}) as Map<String, dynamic>,
  );

  Future<void> deleteShelf(int id) => _delete('/api/shelves/$id');

  // --- books ---------------------------------------------------------------

  Future<List<Book>> listBooks() async => (await _get('/api/books') as List)
      .cast<Map<String, dynamic>>()
      .map(Book.fromJson)
      .toList();

  Future<Book> getBook(int id) async =>
      Book.fromJson(await _get('/api/books/$id') as Map<String, dynamic>);

  /// Uploads a PDF. [onProgress] receives the fraction of bytes handed to the
  /// HTTP client (0..1). On native platforms this tracks the socket closely;
  /// browsers buffer the whole body first, so there it jumps to 1 early.
  Future<Book> uploadBook({
    required String filename,
    required Uint8List bytes,
    required String title,
    String author = '',
    int pageCount = 0,
    int? shelfId,
    void Function(double)? onProgress,
  }) async {
    final req = http.MultipartRequest('POST', _uri('/api/books'))
      ..headers.addAll(_headers(json: false))
      ..fields['title'] = title
      ..fields['author'] = author
      ..fields['page_count'] = '$pageCount';
    if (shelfId != null) req.fields['shelf_id'] = '$shelfId';
    req.files.add(
      http.MultipartFile(
        'file',
        _chunked(bytes, onProgress),
        bytes.length,
        filename: filename,
      ),
    );
    final res = await _send(
      () async {
        final streamed = await _client.send(req);
        return http.Response.fromStream(streamed);
      },
      timeout: _transferTimeout,
    );
    return Book.fromJson(_json(res) as Map<String, dynamic>);
  }

  static Stream<List<int>> _chunked(Uint8List bytes, void Function(double)? onProgress) async* {
    const chunk = 64 * 1024;
    final total = bytes.length;
    if (total == 0) {
      onProgress?.call(1);
      return;
    }
    for (var offset = 0; offset < total; offset += chunk) {
      final end = math.min(offset + chunk, total);
      yield Uint8List.sublistView(bytes, offset, end);
      onProgress?.call(end / total);
    }
  }

  Future<Book> patchBook(
    int id, {
    String? title,
    String? author,
    int? shelfId,
    int? pageCount,
  }) async => Book.fromJson(
    await _patch('/api/books/$id', {
          'title': ?title,
          'author': ?author,
          'shelf_id': ?shelfId,
          'page_count': ?pageCount,
        })
        as Map<String, dynamic>,
  );

  Future<void> deleteBook(int id) => _delete('/api/books/$id');

  Future<Book> putProgress(int id, int page, double pageOffset, DateTime at) async =>
      Book.fromJson(
        await _put('/api/books/$id/progress', {
              'current_page': page,
              'page_offset': pageOffset,
              'updated_at': at.toUtc().toIso8601String(),
            })
            as Map<String, dynamic>,
      );

  /// Downloads the PDF bytes, reporting progress in 0..1 when the size is known.
  Future<Uint8List> downloadBook(
    int id, {
    void Function(double)? onProgress,
  }) async {
    final req = http.Request('GET', _uri('/api/books/$id/file'))
      ..headers.addAll(_headers(json: false));
    http.StreamedResponse res;
    try {
      res = await _client.send(req).timeout(_connectTimeout);
    } on http.ClientException catch (e) {
      throw NetworkException(e.message);
    } on TimeoutException {
      throw NetworkException('Request timed out');
    }
    if (res.statusCode == 401) _onUnauthorized?.call();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(res.statusCode, 'download failed');
    }
    final total = res.contentLength ?? 0;
    final builder = BytesBuilder(copy: false);
    var received = 0;
    try {
      await for (final chunk in res.stream.timeout(_transferTimeout)) {
        builder.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } on http.ClientException catch (e) {
      throw NetworkException(e.message);
    } on TimeoutException {
      throw NetworkException('Download stalled');
    }
    return builder.takeBytes();
  }

  void close() => _client.close();
}
