import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/server_config.dart';

/// Focus mode is a per-device preference (it depends on the screen you are
/// holding, not on the account), so it lives in SharedPreferences rather than
/// in the synced reader settings.
class FocusModeNotifier extends Notifier<bool> {
  static const _key = 'focus_mode';

  @override
  bool build() => ref.read(sharedPrefsProvider).getBool(_key) ?? false;

  Future<void> set(bool on) async {
    state = on;
    await ref.read(sharedPrefsProvider).setBool(_key, on);
  }

  Future<void> toggle() => set(!state);
}

final focusModeProvider = NotifierProvider<FocusModeNotifier, bool>(FocusModeNotifier.new);

/// Tapping the left or right edge of the reader moves one screen back or
/// forward. A per-device preference, like focus mode.
class EdgeTapNotifier extends Notifier<bool> {
  static const _key = 'edge_tap';

  @override
  bool build() => ref.read(sharedPrefsProvider).getBool(_key) ?? true;

  Future<void> set(bool on) async {
    state = on;
    await ref.read(sharedPrefsProvider).setBool(_key, on);
  }
}

final edgeTapProvider = NotifierProvider<EdgeTapNotifier, bool>(EdgeTapNotifier.new);
