import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Injected in `main` once SharedPreferences has been loaded.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (_) => throw UnimplementedError('sharedPrefsProvider must be overridden'),
);

/// Normalises user input such as `192.168.1.10:8080` into an origin string.
String? normalizeServerUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'http://$s';
  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.replace(path: '', query: null, fragment: null).origin;
}

/// Holds the server origin the app talks to.
///
/// On web it is always the origin the page was served from (the Go server
/// hosts the web build). On mobile it is entered once in the setup screen and
/// persisted.
class ServerUrlNotifier extends Notifier<String?> {
  static const _key = 'server_url';

  @override
  String? build() {
    if (kIsWeb) return Uri.base.origin;
    return ref.read(sharedPrefsProvider).getString(_key);
  }

  bool get isFixed => kIsWeb;

  Future<void> set(String origin) async {
    if (kIsWeb) return;
    await ref.read(sharedPrefsProvider).setString(_key, origin);
    state = origin;
  }

  Future<void> clear() async {
    if (kIsWeb) return;
    await ref.read(sharedPrefsProvider).remove(_key);
    state = null;
  }
}

final serverUrlProvider = NotifierProvider<ServerUrlNotifier, String?>(
  ServerUrlNotifier.new,
);
