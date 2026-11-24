import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/server_config.dart';

/// Eye-break reminder (the 20-20-20 rule): after [intervalMinutes] of reading,
/// the page is blurred for [breakSeconds] so the reader looks away from the
/// screen. A per-device preference.
@immutable
class EyeBreakSettings {
  const EyeBreakSettings({
    this.enabled = false,
    this.intervalMinutes = defaultMinutes,
    this.breakSeconds = defaultSeconds,
  });

  static const defaultMinutes = 20;
  static const defaultSeconds = 20;
  static const minMinutes = 5;
  static const maxMinutes = 60;
  static const minSeconds = 10;
  static const maxSeconds = 60;

  final bool enabled;
  final int intervalMinutes;
  final int breakSeconds;

  EyeBreakSettings copyWith({
    bool? enabled,
    int? intervalMinutes,
    int? breakSeconds,
  }) => EyeBreakSettings(
    enabled: enabled ?? this.enabled,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    breakSeconds: breakSeconds ?? this.breakSeconds,
  );

  @override
  bool operator ==(Object other) =>
      other is EyeBreakSettings &&
      other.enabled == enabled &&
      other.intervalMinutes == intervalMinutes &&
      other.breakSeconds == breakSeconds;

  @override
  int get hashCode => Object.hash(enabled, intervalMinutes, breakSeconds);
}

class EyeBreakNotifier extends Notifier<EyeBreakSettings> {
  static const _enabledKey = 'eye_break';
  static const _minutesKey = 'eye_break_minutes';
  static const _secondsKey = 'eye_break_seconds';

  @override
  EyeBreakSettings build() {
    final prefs = ref.read(sharedPrefsProvider);
    return EyeBreakSettings(
      enabled: prefs.getBool(_enabledKey) ?? false,
      intervalMinutes:
          (prefs.getInt(_minutesKey) ?? EyeBreakSettings.defaultMinutes).clamp(
            EyeBreakSettings.minMinutes,
            EyeBreakSettings.maxMinutes,
          ),
      breakSeconds:
          (prefs.getInt(_secondsKey) ?? EyeBreakSettings.defaultSeconds).clamp(
            EyeBreakSettings.minSeconds,
            EyeBreakSettings.maxSeconds,
          ),
    );
  }

  Future<void> setEnabled(bool on) async {
    state = state.copyWith(enabled: on);
    await ref.read(sharedPrefsProvider).setBool(_enabledKey, on);
  }

  Future<void> setIntervalMinutes(int minutes) async {
    state = state.copyWith(intervalMinutes: minutes);
    await ref.read(sharedPrefsProvider).setInt(_minutesKey, minutes);
  }

  Future<void> setBreakSeconds(int seconds) async {
    state = state.copyWith(breakSeconds: seconds);
    await ref.read(sharedPrefsProvider).setInt(_secondsKey, seconds);
  }
}

final eyeBreakProvider = NotifierProvider<EyeBreakNotifier, EyeBreakSettings>(
  EyeBreakNotifier.new,
);

/// Wraps the reader. While eye breaks are on, it counts reading time (only
/// while the app is in the foreground) and, when the interval is up, blurs
/// [child] behind a countdown. Input to the page is blocked during the break;
/// it can be skipped.
class EyeBreakOverlay extends ConsumerStatefulWidget {
  const EyeBreakOverlay({super.key, required this.child, this.foreground});

  final Widget child;

  /// Colour of the countdown text; defaults to the theme's onSurface.
  final Color? foreground;

  @override
  ConsumerState<EyeBreakOverlay> createState() => _EyeBreakOverlayState();
}

class _EyeBreakOverlayState extends ConsumerState<EyeBreakOverlay> {
  Timer? _ticker;

  /// Seconds read since the last break.
  int _readSeconds = 0;

  /// Seconds left in the current break, or null when not on a break.
  int? _breakLeft;

  bool _visible = true;

  late final _lifecycle = AppLifecycleListener(
    onShow: () => _visible = true,
    onHide: () => _visible = false,
  );

  @override
  void initState() {
    super.initState();
    _lifecycle; // start listening
    _sync(ref.read(eyeBreakProvider));
  }

  void _sync(EyeBreakSettings s) {
    if (s.enabled) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else {
      _ticker?.cancel();
      _ticker = null;
      _readSeconds = 0;
      if (_breakLeft != null) setState(() => _breakLeft = null);
    }
  }

  void _tick() {
    if (!_visible) return;
    final s = ref.read(eyeBreakProvider);
    final left = _breakLeft;
    if (left != null) {
      setState(() => _breakLeft = left > 1 ? left - 1 : null);
      return;
    }
    _readSeconds++;
    if (_readSeconds >= s.intervalMinutes * 60) {
      _readSeconds = 0;
      setState(() => _breakLeft = s.breakSeconds);
    }
  }

  void _skip() => setState(() {
    _breakLeft = null;
    _readSeconds = 0;
  });

  @override
  void dispose() {
    _ticker?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(eyeBreakProvider, (prev, next) {
      // A new interval starts counting from now.
      if (prev?.intervalMinutes != next.intervalMinutes) _readSeconds = 0;
      _sync(next);
    });
    final left = _breakLeft;
    final total = ref.watch(eyeBreakProvider.select((s) => s.breakSeconds));
    final onBreak = left != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: onBreak,
          child: AbsorbPointer(absorbing: onBreak, child: widget.child),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: onBreak
              ? _BreakPanel(
                  key: const ValueKey('eye-break'),
                  secondsLeft: left,
                  totalSeconds: total,
                  foreground: widget.foreground,
                  onSkip: _skip,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _BreakPanel extends StatelessWidget {
  const _BreakPanel({
    super.key,
    required this.secondsLeft,
    required this.totalSeconds,
    required this.onSkip,
    this.foreground,
  });

  final int secondsLeft;
  final int totalSeconds;
  final VoidCallback onSkip;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = foreground ?? theme.colorScheme.onSurface;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: ColoredBox(
          color: theme.colorScheme.surface.withValues(alpha: 0.35),
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.visibility_outlined, color: fg, size: 32),
                    const SizedBox(height: 12),
                    Text(
                      'Rest your eyes',
                      style: theme.textTheme.headlineSmall?.copyWith(color: fg),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Look at something about 20 feet (6 m) away.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: fg.withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: 120,
                      height: 120,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CircularProgressIndicator(
                            value: secondsLeft / totalSeconds,
                            strokeWidth: 4,
                            color: fg,
                            backgroundColor: fg.withValues(alpha: 0.15),
                          ),
                          Center(
                            child: Text(
                              '$secondsLeft',
                              style: theme.textTheme.displayMedium?.copyWith(
                                color: fg,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextButton(
                      onPressed: onSkip,
                      style: TextButton.styleFrom(foregroundColor: fg),
                      child: const Text('Skip'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
