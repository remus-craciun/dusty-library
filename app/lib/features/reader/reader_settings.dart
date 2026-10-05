import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import 'focus_mode.dart';

/// Reader preferences (zoom and page filter), synced with the server and cached
/// locally so they are available offline.
class ReaderSettingsNotifier extends AsyncNotifier<ReaderSettings> {
  @override
  Future<ReaderSettings> build() async {
    final api = ref.watch(apiClientProvider);
    final cache = ref.read(localCacheProvider);
    try {
      final remote = await api.getSettings();
      await cache.writeSettings(remote);
      return remote;
    } on NetworkException {
      return await cache.readSettings() ?? const ReaderSettings();
    } on ApiException {
      return await cache.readSettings() ?? const ReaderSettings();
    }
  }

  ReaderSettings get current => state.asData?.value ?? const ReaderSettings();

  Future<void> save(ReaderSettings s) async {
    state = AsyncData(s);
    final cache = ref.read(localCacheProvider);
    await cache.writeSettings(s);
    try {
      await ref.read(apiClientProvider).putSettings(s);
    } on NetworkException {
      // Local copy is kept; server gets it on the next successful save.
    } on ApiException {
      // Ignore validation surprises; the local copy still applies.
    }
  }

  Future<void> setZoom(double zoom) =>
      save(current.copyWith(zoom: zoom.clamp(ReaderSettings.minZoom, ReaderSettings.maxZoom)));

  Future<void> setFilter(PageFilter filter) => save(current.copyWith(filter: filter));
}

final readerSettingsProvider =
    AsyncNotifierProvider<ReaderSettingsNotifier, ReaderSettings>(ReaderSettingsNotifier.new);

/// Visual recipe for a [PageFilter]: a colour matrix applied to the rendered
/// pages plus matching chrome colours.
class FilterStyle {
  const FilterStyle({
    required this.matrix,
    required this.viewerBackground,
    required this.chromeBackground,
    required this.chromeForeground,
  });

  /// 4x5 colour matrix for [ColorFilter.matrix].
  final List<double> matrix;

  /// Colour painted behind pages *before* the matrix is applied. Pages are
  /// shown edge to edge, so this matches paper white and simply inherits the
  /// filter (grey for old paper, near-black for dark) wherever it peeks through.
  final Color viewerBackground;
  final Color chromeBackground;
  final Color chromeForeground;

  ColorFilter get colorFilter => ColorFilter.matrix(matrix);

  static FilterStyle of(PageFilter f) => switch (f) {
    PageFilter.none => const FilterStyle(
      matrix: _identity,
      viewerBackground: Colors.white,
      chromeBackground: Color(0xFFFAFAFA),
      chromeForeground: Color(0xFF1F1F1F),
    ),
    // Multiplies each channel so pure white becomes the grey of aged paper
    // while ink stays dark. The channels are almost equal, so the tint reads
    // as grey rather than cream.
    PageFilter.paper => FilterStyle(
      matrix: _tint(ReaderPalette.paper),
      viewerBackground: Colors.white,
      chromeBackground: ReaderPalette.paper,
      chromeForeground: ReaderPalette.paperInk,
    ),
    PageFilter.sepia => const FilterStyle(
      matrix: [
        0.393, 0.769, 0.189, 0, 0, //
        0.349, 0.686, 0.168, 0, 0, //
        0.272, 0.534, 0.131, 0, 0, //
        0, 0, 0, 1, 0,
      ],
      viewerBackground: Colors.white,
      chromeBackground: ReaderPalette.sepia,
      chromeForeground: ReaderPalette.sepiaInk,
    ),
    // Inverts luminance and dims slightly so white paper becomes near-black and
    // text becomes soft light grey instead of glaring white.
    PageFilter.dark => const FilterStyle(
      matrix: [
        -0.85, 0, 0, 0, 230, //
        0, -0.85, 0, 0, 228, //
        0, 0, -0.85, 0, 224, //
        0, 0, 0, 1, 0,
      ],
      viewerBackground: Colors.white,
      chromeBackground: ReaderPalette.dark,
      chromeForeground: ReaderPalette.darkInk,
    ),
  };

  static const _identity = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0,
  ];

  static List<double> _tint(Color c) => [
    c.r, 0, 0, 0, 0, //
    0, c.g, 0, 0, 0, //
    0, 0, c.b, 0, 0, //
    0, 0, 0, 1, 0,
  ];
}

/// Bottom sheet with the zoom slider and filter choices.
class ReaderSettingsSheet extends ConsumerWidget {
  const ReaderSettingsSheet({super.key, required this.onZoomChanged});

  /// Called with the new relative zoom so the open viewer can apply it live.
  final ValueChanged<double> onZoomChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerSettingsProvider).asData?.value ?? const ReaderSettings();
    final notifier = ref.read(readerSettingsProvider.notifier);
    final focus = ref.watch(focusModeProvider);
    final edgeTap = ref.watch(edgeTapProvider);
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: focus,
              onChanged: (v) => ref.read(focusModeProvider.notifier).set(v),
              title: const Text('Focus mode'),
              subtitle: const Text('Trim page margins so the text fills the screen width and keep the screen awake.'),
              secondary: FocusIcon(active: focus),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: edgeTap,
              onChanged: (v) => ref.read(edgeTapProvider.notifier).set(v),
              title: const Text('Edge taps'),
              subtitle: const Text('Tap the left or right 20% of the screen to move back or forward by one screen.'),
              secondary: const Icon(Icons.touch_app_outlined),
            ),
            const SizedBox(height: 8),
            Text('Text size', style: theme.textTheme.titleMedium),
            if (focus)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'In focus mode the text is sized to the width of the screen.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            else
              Row(
                children: [
                  const Icon(Icons.text_decrease),
                  Expanded(
                    child: Slider(
                      value: settings.zoom,
                      min: ReaderSettings.minZoom,
                      max: ReaderSettings.maxZoom,
                      divisions: 18,
                      label: '${(settings.zoom * 100).round()}%',
                      onChanged: (v) {
                        notifier.setZoom(v);
                        onZoomChanged(v);
                      },
                    ),
                  ),
                  const Icon(Icons.text_increase),
                ],
              ),
            const SizedBox(height: 8),
            Text('Page colour', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final f in PageFilter.values)
                  _FilterChip(filter: f, selected: settings.filter == f, onTap: () => notifier.setFilter(f)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Focus-mode mark drawn directly, so it does not depend on a Material icon
/// glyph. The web build subsets that font, and a browser can keep serving the
/// first subset, which leaves this icon blank.
class FocusIcon extends StatelessWidget {
  const FocusIcon({super.key, this.active = false});
  final bool active;

  @override
  Widget build(BuildContext context) {
    final size = IconTheme.of(context).size ?? 24;
    final color = IconTheme.of(context).color ?? const Color(0xFF1F1F1F);
    return CustomPaint(
      size: Size.square(size),
      painter: _FocusIconPainter(color: color, active: active),
    );
  }
}

class _FocusIconPainter extends CustomPainter {
  const _FocusIconPainter({required this.color, required this.active});
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.08
      ..strokeCap = StrokeCap.square;
    final inset = size.width * 0.1;
    final arm = size.width * 0.26;
    void corner(Offset origin, double dx, double dy) {
      canvas.drawLine(origin, origin + Offset(dx, 0), stroke);
      canvas.drawLine(origin, origin + Offset(0, dy), stroke);
    }

    corner(Offset(inset, inset), arm, arm);
    corner(Offset(size.width - inset, inset), -arm, arm);
    corner(Offset(inset, size.height - inset), arm, -arm);
    corner(Offset(size.width - inset, size.height - inset), -arm, -arm);
    final center = size.center(Offset.zero);
    final radius = size.width * 0.16;
    if (active) {
      canvas.drawCircle(center, radius, Paint()..color = color);
    } else {
      canvas.drawCircle(center, radius, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _FocusIconPainter old) => old.color != color || old.active != active;
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.filter, required this.selected, required this.onTap});
  final PageFilter filter;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = FilterStyle.of(filter);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 84,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: style.chromeBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 2.5 : 1),
        ),
        child: Column(
          children: [
            Text('Aa', style: TextStyle(color: style.chromeForeground, fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(filter.label, style: TextStyle(color: style.chromeForeground, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
