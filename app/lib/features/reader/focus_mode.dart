import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/server_config.dart';

/// Focus mode lasts only while this book is open. The next time a book is
/// opened it starts off, even if it was on for the previous reading.
class FocusModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool on) => state = on;

  void toggle() => set(!state);
}

/// Dropped when the reader closes, so the next book starts with focus mode off.
final focusModeProvider = NotifierProvider.autoDispose<FocusModeNotifier, bool>(
  FocusModeNotifier.new,
);

/// Tapping the left or right edge of the reader moves one screen back or
/// forward. A per-device preference.
class EdgeTapNotifier extends Notifier<bool> {
  static const _key = 'edge_tap';

  @override
  bool build() => ref.read(sharedPrefsProvider).getBool(_key) ?? true;

  Future<void> set(bool on) async {
    state = on;
    await ref.read(sharedPrefsProvider).setBool(_key, on);
  }
}

final edgeTapProvider = NotifierProvider<EdgeTapNotifier, bool>(
  EdgeTapNotifier.new,
);

/// Page turns are animated: text pages slide in from the side they come
/// from, PDF screens scroll. Off, a turn shows the next page at once. A
/// per-device preference.
class PageAnimationNotifier extends Notifier<bool> {
  static const _key = 'page_animation';

  @override
  bool build() => ref.read(sharedPrefsProvider).getBool(_key) ?? true;

  Future<void> set(bool on) async {
    state = on;
    await ref.read(sharedPrefsProvider).setBool(_key, on);
  }
}

final pageAnimationProvider = NotifierProvider<PageAnimationNotifier, bool>(
  PageAnimationNotifier.new,
);
