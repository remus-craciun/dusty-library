import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_screen.dart';
import '../features/library/library_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/setup/server_setup_screen.dart';
import 'server_config.dart';
import 'session.dart';

class Routes {
  static const setup = '/setup';
  static const auth = '/auth';
  static const library = '/';
  static String reader(int bookId) => '/read/$bookId';
}

/// Pings GoRouter whenever the session or server URL changes so redirects
/// are re-evaluated without rebuilding the router itself.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(sessionProvider, (_, _) => notifyListeners());
    ref.listen(serverUrlProvider, (_, _) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.library,
    refreshListenable: refresh,
    debugLogDiagnostics: kDebugMode,
    redirect: (context, state) {
      final hasServer = ref.read(serverUrlProvider) != null;
      final signedIn = ref.read(sessionProvider).isAuthenticated;
      final loc = state.matchedLocation;

      if (!hasServer) return loc == Routes.setup ? null : Routes.setup;
      if (!signedIn) return loc == Routes.auth ? null : Routes.auth;
      if (loc == Routes.setup || loc == Routes.auth) return Routes.library;
      return null;
    },
    routes: [
      GoRoute(
        path: Routes.setup,
        builder: (_, _) => const ServerSetupScreen(),
      ),
      GoRoute(path: Routes.auth, builder: (_, _) => const AuthScreen()),
      GoRoute(
        path: Routes.library,
        builder: (_, _) => const LibraryScreen(),
        routes: [
          GoRoute(
            path: 'read/:id',
            builder: (_, state) =>
                ReaderScreen(bookId: int.parse(state.pathParameters['id']!)),
          ),
        ],
      ),
    ],
  );
});
