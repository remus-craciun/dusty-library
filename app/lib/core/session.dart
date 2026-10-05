import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/local_cache.dart';
import '../data/models.dart';
import 'api_client.dart';
import 'server_config.dart';

/// Authenticated user state.
class Session {
  const Session({this.token, this.username});
  final String? token;
  final String? username;

  bool get isAuthenticated => token != null && token!.isNotEmpty;

  static const empty = Session();
}

/// Injected in `main` with the session restored from secure storage.
final initialSessionProvider = Provider<Session>((_) => Session.empty);

/// Injected in `main` with the opened platform cache.
final localCacheProvider = Provider<LocalCache>(
  (_) => throw UnimplementedError('localCacheProvider must be overridden'),
);

class SessionStore {
  SessionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  static const _tokenKey = 'auth_token';
  static const _userKey = 'auth_user';

  Future<Session> read() async {
    try {
      final token = await _storage.read(key: _tokenKey);
      final user = await _storage.read(key: _userKey);
      return Session(token: token, username: user);
    } catch (_) {
      return Session.empty;
    }
  }

  Future<void> write(Session s) async {
    await _storage.write(key: _tokenKey, value: s.token);
    await _storage.write(key: _userKey, value: s.username);
  }

  Future<void> clear() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userKey);
  }
}

class SessionNotifier extends Notifier<Session> {
  final _store = SessionStore();

  @override
  Session build() => ref.read(initialSessionProvider);

  Future<void> signIn(AuthResult result) async {
    final s = Session(token: result.token, username: result.username);
    await _store.write(s);
    state = s;
  }

  /// Revokes the token on the server, then clears credentials and all cached
  /// data on this device. Tokens never expire on their own, so this is the
  /// only thing that invalidates them.
  Future<void> signOut({bool everywhere = false}) async {
    if (state.isAuthenticated) {
      try {
        final api = ref.read(apiClientProvider);
        await (everywhere ? api.logoutAll() : api.logout());
      } catch (_) {
        // Offline or already revoked: still sign out locally. The server-side
        // session can be cleaned up later via "sign out everywhere".
      }
    }
    await _store.clear();
    await ref.read(localCacheProvider).clear();
    state = Session.empty;
  }

  /// Called by the API client on 401: drop the token so the router goes back
  /// to the login screen, but keep cached data.
  void expire() {
    if (!state.isAuthenticated) return;
    _store.clear();
    state = Session.empty;
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, Session>(
  SessionNotifier.new,
);

/// API client bound to the current server and token. Rebuilt whenever either
/// changes.
final apiClientProvider = Provider<ApiClient>((ref) {
  final baseUrl = ref.watch(serverUrlProvider) ?? '';
  final client = ApiClient(
    baseUrl: baseUrl,
    token: () => ref.read(sessionProvider).token,
    onUnauthorized: () => ref.read(sessionProvider.notifier).expire(),
  );
  ref.onDispose(client.close);
  return client;
});

/// Whether an account already exists on the server (register vs login).
final serverStatusProvider = FutureProvider<ServerStatus>((ref) async {
  ref.watch(serverUrlProvider);
  return ref.watch(apiClientProvider).status();
});
