import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Phases of adding a book, reported by [LibraryNotifier.upload].
enum UploadStage { reading, counting, uploading, processing, done, failed }

/// Observable upload state shared between the upload routine and the dialog.
class UploadProgress extends ChangeNotifier {
  UploadStage _stage = UploadStage.reading;
  double _fraction = 0;
  Object? _error;

  UploadStage get stage => _stage;

  /// Bytes sent so far in 0..1 (only meaningful during [UploadStage.uploading]).
  double get fraction => _fraction;
  Object? get error => _error;

  void setStage(UploadStage s) {
    if (_stage == s) return;
    _stage = s;
    notifyListeners();
  }

  void setFraction(double f) {
    final clamped = f.clamp(0.0, 1.0);
    if ((clamped - _fraction).abs() < 0.005 && clamped != 1) return;
    _fraction = clamped;
    if (_fraction >= 1 && _stage == UploadStage.uploading) {
      _stage = UploadStage.processing;
    }
    notifyListeners();
  }

  void fail(Object e) {
    _error = e;
    _stage = UploadStage.failed;
    notifyListeners();
  }

  void finish() => setStage(UploadStage.done);
}

/// Shows the upload dialog for [future], which must drive [progress]. The
/// dialog shows a short success animation before closing on its own; on
/// failure it closes immediately so the caller can surface the error.
Future<T> showUploadDialog<T>(
  BuildContext context, {
  required String filename,
  required UploadProgress progress,
  required Future<T> future,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var closed = false;
  // ignore: unawaited_futures
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'Uploading',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 260),
    transitionBuilder: (_, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
      return FadeTransition(
        opacity: anim,
        child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(curved), child: child),
      );
    },
    pageBuilder: (_, _, _) => PopScope(
      canPop: false,
      child: Center(child: UploadDialog(filename: filename, progress: progress)),
    ),
  ).whenComplete(() => closed = true);

  try {
    final result = await future;
    progress.finish();
    // Let the check mark play before dismissing.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    return result;
  } catch (e) {
    progress.fail(e);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    rethrow;
  } finally {
    if (!closed && navigator.mounted) navigator.pop();
  }
}

class UploadDialog extends StatelessWidget {
  const UploadDialog({super.key, required this.filename, required this.progress});

  final String filename;
  final UploadProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: 320,
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
        ),
        child: ListenableBuilder(
          listenable: progress,
          builder: (context, _) {
            final stage = progress.stage;
            final (label, hint) = _copy(stage);
            final showBar = stage == UploadStage.uploading || stage == UploadStage.processing;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 120,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    switchInCurve: Curves.easeOutBack,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
                    child: switch (stage) {
                      UploadStage.done => _ResultBadge(key: const ValueKey('done'), icon: Icons.check_rounded, color: scheme.primary),
                      UploadStage.failed => _ResultBadge(key: const ValueKey('failed'), icon: Icons.close_rounded, color: scheme.error),
                      _ => const _UploadAnimation(key: ValueKey('busy')),
                    },
                  ),
                ),
                const SizedBox(height: 16),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(label, key: ValueKey(label), style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                ),
                const SizedBox(height: 4),
                Text(
                  hint ?? filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: showBar ? 1 : 0.35,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: TweenAnimationBuilder<double>(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      tween: Tween(end: switch (stage) {
                        UploadStage.reading => 0.05,
                        UploadStage.counting => 0.12,
                        UploadStage.uploading => 0.12 + progress.fraction * 0.83,
                        UploadStage.processing => 0.97,
                        UploadStage.done || UploadStage.failed => 1.0,
                      }),
                      builder: (_, v, _) => LinearProgressIndicator(
                        value: stage == UploadStage.processing ? null : v,
                        minHeight: 8,
                        color: stage == UploadStage.failed ? scheme.error : null,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  switch (stage) {
                    UploadStage.uploading => '${(progress.fraction * 100).round()}%',
                    UploadStage.processing => 'Almost there…',
                    UploadStage.done => 'Added to your library',
                    UploadStage.failed => 'Something went wrong',
                    _ => ' ',
                  },
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static (String, String?) _copy(UploadStage s) => switch (s) {
    UploadStage.reading => ('Reading file', null),
    UploadStage.counting => ('Counting pages', null),
    UploadStage.uploading => ('Uploading', null),
    UploadStage.processing => ('Shelving your book', null),
    UploadStage.done => ('Done', null),
    UploadStage.failed => ('Upload failed', null),
  };
}

/// A page that lifts out of a book and floats up into a cloud, on repeat.
class _UploadAnimation extends StatefulWidget {
  const _UploadAnimation({super.key});

  @override
  State<_UploadAnimation> createState() => _UploadAnimationState();
}

class _UploadAnimationState extends State<_UploadAnimation> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        // Page: rises from the book (y=+34) to the cloud (y=-30), fading at both ends.
        final rise = Curves.easeInOutCubic.transform(t);
        final y = 34 - 64 * rise;
        final opacity = math.sin(t * math.pi).clamp(0.0, 1.0);
        final tilt = math.sin(t * math.pi * 2) * 0.12;
        // Cloud: gentle bob and a pulse when the page arrives.
        final bob = math.sin(t * math.pi * 2) * 2;
        final pulse = 1 + 0.08 * math.exp(-math.pow((t - 0.95).abs() * 14, 2));
        // Ring: expands outwards as the page leaves the book.
        final ringT = ((t - 0.05) / 0.5).clamp(0.0, 1.0);

        return Stack(
          alignment: Alignment.center,
          children: [
            // Expanding ring.
            Positioned(
              bottom: 8,
              child: Opacity(
                opacity: (1 - ringT) * 0.5,
                child: Container(
                  width: 24 + 70 * ringT,
                  height: 10 + 20 * ringT,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.primary, width: 2),
                  ),
                ),
              ),
            ),
            // Cloud.
            Positioned(
              top: 0,
              child: Transform.translate(
                offset: Offset(0, bob),
                child: Transform.scale(
                  scale: pulse,
                  child: Icon(Icons.cloud_upload_outlined, size: 48, color: scheme.primary),
                ),
              ),
            ),
            // Rising page.
            Transform.translate(
              offset: Offset(math.sin(t * math.pi * 3) * 3, y),
              child: Transform.rotate(
                angle: tilt,
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: 26,
                    height: 34,
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: scheme.outlineVariant),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 6, offset: const Offset(0, 3))],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < 4; i++)
                          Container(
                            margin: const EdgeInsets.symmetric(vertical: 1.5),
                            width: i == 3 ? 10 : 16,
                            height: 2,
                            color: scheme.outlineVariant,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Open book at the bottom.
            Positioned(
              bottom: 0,
              child: Icon(Icons.auto_stories, size: 40, color: scheme.secondary),
            ),
          ],
        );
      },
    );
  }
}

class _ResultBadge extends StatelessWidget {
  const _ResultBadge({super.key, required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 600),
      curve: Curves.elasticOut,
      tween: Tween(begin: 0.6, end: 1),
      builder: (_, v, child) => Transform.scale(scale: v, child: child),
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
        child: Icon(icon, size: 48, color: color),
      ),
    );
  }
}
