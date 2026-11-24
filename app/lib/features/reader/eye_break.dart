import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Wraps the reader. While eye breaks are on, it counts reading time and,
/// when the interval is up, blurs the whole app (open sheets included) behind
/// a countdown. Input is blocked during the break; it can be skipped, and the
/// phone vibrates when it ends on its own.
///
/// Time away counts as a break: the count starts over after the app has been
/// in the background for at least the break length, or after [idleLimit]
/// without a tap, swipe or key press on the page.
class EyeBreakOverlay extends ConsumerStatefulWidget {
  const EyeBreakOverlay({
    super.key,
    required this.child,
    this.foreground,
    this.idleLimit = const Duration(minutes: 5),
    this.now = DateTime.now,
  });

  final Widget child;

  /// Colour of the countdown text; defaults to the theme's onSurface.
  final Color? foreground;

  /// With no input on the page for this long, the reader is taken to be away:
  /// reading time stops counting and starts over on the next input.
  final Duration idleLimit;

  /// Wall clock, used to measure time spent in the background.
  final DateTime Function() now;

  @override
  ConsumerState<EyeBreakOverlay> createState() => _EyeBreakOverlayState();
}

class _EyeBreakOverlayState extends ConsumerState<EyeBreakOverlay> {
  Timer? _ticker;
  Timer? _buzz;

  /// Seconds read since the last break.
  int _readSeconds = 0;

  /// Seconds in the foreground with no input on the page.
  int _idleSeconds = 0;

  /// Seconds left in the current break, or null when not on a break.
  int? _breakLeft;

  bool _visible = true;
  DateTime? _hiddenAt;

  /// The break panel, shown in the root overlay so it covers open sheets.
  OverlayEntry? _entry;
  bool _panelShown = false;

  /// Last countdown value, kept on screen while the panel fades out.
  int _lastSeconds = 0;

  late final _lifecycle = AppLifecycleListener(
    onShow: _onShow,
    onHide: () {
      _visible = false;
      _hiddenAt = widget.now();
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle; // start listening
    _sync(ref.read(eyeBreakProvider));
  }

  void _onShow() {
    _visible = true;
    final hiddenAt = _hiddenAt;
    _hiddenAt = null;
    if (hiddenAt == null) return;
    final away = widget.now().difference(hiddenAt);
    if (away.inSeconds >= ref.read(eyeBreakProvider).breakSeconds) {
      _restart();
    }
  }

  void _onActivity() {
    if (_idleSeconds >= widget.idleLimit.inSeconds) _readSeconds = 0;
    _idleSeconds = 0;
  }

  void _sync(EyeBreakSettings s) {
    if (s.enabled) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else {
      _ticker?.cancel();
      _ticker = null;
      _restart();
    }
  }

  void _tick() {
    if (!_visible) return;
    final s = ref.read(eyeBreakProvider);
    final left = _breakLeft;
    if (left != null) {
      if (left > 1) {
        _setBreak(left - 1);
      } else {
        _restart();
        _vibrate();
      }
      return;
    }
    if (_idleSeconds < widget.idleLimit.inSeconds) _idleSeconds++;
    if (_idleSeconds >= widget.idleLimit.inSeconds) return; // away
    _readSeconds++;
    if (_readSeconds >= s.intervalMinutes * 60) {
      _readSeconds = 0;
      _setBreak(s.breakSeconds);
    }
  }

  /// Ends any break and starts counting reading time from zero.
  void _restart() {
    _readSeconds = 0;
    _idleSeconds = 0;
    if (_breakLeft != null) _setBreak(null);
  }

  void _vibrate() {
    HapticFeedback.vibrate();
    _buzz?.cancel();
    _buzz = Timer(const Duration(milliseconds: 300), HapticFeedback.vibrate);
  }

  void _setBreak(int? left) {
    if (!mounted) return;
    setState(() => _breakLeft = left);
    if (left != null) {
      _lastSeconds = left;
      _panelShown = true;
      if (_entry == null) {
        // Insert transparent, then fade in on the next frame.
        _panelShown = false;
        _entry = OverlayEntry(builder: _buildEntry);
        Overlay.of(context, rootOverlay: true).insert(_entry!);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_entry == null || _breakLeft == null) return;
          _panelShown = true;
          _entry!.markNeedsBuild();
        });
      }
    } else {
      _panelShown = false;
    }
    _entry?.markNeedsBuild();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }

  Widget _buildEntry(BuildContext context) {
    final total = ref.read(eyeBreakProvider).breakSeconds;
    final left = _breakLeft;
    return IgnorePointer(
      ignoring: left == null,
      child: AnimatedOpacity(
        opacity: _panelShown ? 1 : 0,
        duration: const Duration(milliseconds: 400),
        onEnd: () {
          if (!_panelShown && _breakLeft == null) _removeEntry();
        },
        // Opaque, so taps never reach the page or a sheet underneath.
        child: Listener(
          behavior: HitTestBehavior.opaque,
          child: Material(
            type: MaterialType.transparency,
            child: _BreakPanel(
              secondsLeft: left ?? _lastSeconds,
              totalSeconds: total,
              foreground: widget.foreground,
              onSkip: _restart,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _buzz?.cancel();
    _lifecycle.dispose();
    _removeEntry();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(eyeBreakProvider, (prev, next) {
      // A new interval starts counting from now.
      if (prev?.intervalMinutes != next.intervalMinutes) _readSeconds = 0;
      _sync(next);
    });
    final onBreak = _breakLeft != null;

    return Listener(
      // Any touch on the reader counts, even on blank margins.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _onActivity(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, _) {
          _onActivity();
          return KeyEventResult.ignored;
        },
        child: ExcludeFocus(
          excluding: onBreak,
          child: AbsorbPointer(absorbing: onBreak, child: widget.child),
        ),
      ),
    );
  }
}

class _BreakPanel extends StatelessWidget {
  const _BreakPanel({
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
