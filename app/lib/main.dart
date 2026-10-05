import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/server_config.dart';
import 'core/session.dart';
import 'data/local_cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Clean URLs on web (/read/12 instead of /#/read/12); the Go server serves
  // index.html for unknown paths so refresh and deep links keep working.
  usePathUrlStrategy();
  await pdfrxFlutterInitialize();

  final results = await Future.wait([
    SharedPreferences.getInstance(),
    SessionStore().read(),
    LocalCache.open(),
  ]);

  runApp(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(results[0] as SharedPreferences),
        initialSessionProvider.overrideWithValue(results[1] as Session),
        localCacheProvider.overrideWithValue(results[2] as LocalCache),
      ],
      child: const DustyApp(),
    ),
  );
}
