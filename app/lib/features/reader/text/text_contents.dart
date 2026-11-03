import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'paginator.dart';

/// Index of the heading the reader is in: the last one at or before
/// [paragraph] (0-based), or -1 before the first.
int currentHeading(List<BookHeading> headings, int paragraph) {
  var found = -1;
  for (var i = 0; i < headings.length; i++) {
    if (headings[i].paragraph > paragraph) break;
    found = i;
  }
  return found;
}

/// Table of contents of a text book: its headings indented by level, with
/// the page each starts on. The heading being read is marked and scrolled
/// into view. Tapping an entry calls [onSelect] with its paragraph.
class TextContentsSheet extends StatefulWidget {
  const TextContentsSheet({
    super.key,
    required this.headings,
    required this.current,
    required this.pageOf,
    required this.onSelect,
  });

  final List<BookHeading> headings;

  /// Index into [headings] of the heading being read, or -1.
  final int current;

  /// Page a paragraph starts on, or null while pages are still being laid
  /// out.
  final int? Function(int paragraph) pageOf;
  final ValueChanged<int> onSelect;

  @override
  State<TextContentsSheet> createState() => _TextContentsSheetState();
}

class _TextContentsSheetState extends State<TextContentsSheet> {
  static const _rowHeight = 48.0;
  bool _scrolled = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headings = widget.headings;
    final top = headings.isEmpty
        ? 1
        : headings.map((h) => h.level).reduce(math.min);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (context, scroll) {
        if (!_scrolled && widget.current > 1) {
          _scrolled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!scroll.hasClients) return;
            final target = (widget.current - 1) * _rowHeight;
            scroll.jumpTo(math.min(target, scroll.position.maxScrollExtent));
          });
        }
        return ListView.builder(
          controller: scroll,
          itemExtent: _rowHeight,
          itemCount: headings.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Contents', style: theme.textTheme.titleMedium),
                ),
              );
            }
            final index = i - 1;
            final h = headings[index];
            final current = index == widget.current;
            final page = widget.pageOf(h.paragraph);
            final depth = (h.level - top).clamp(0, 4);
            return ListTile(
              dense: true,
              selected: current,
              selectedTileColor: theme.colorScheme.primary.withValues(
                alpha: 0.08,
              ),
              contentPadding: EdgeInsets.only(
                left: 16.0 + depth * 20,
                right: 16,
              ),
              title: Text(
                h.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: depth == 0
                    ? const TextStyle(fontWeight: FontWeight.w600)
                    : null,
              ),
              trailing: Text(
                page == null ? '…' : '$page',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              onTap: () => widget.onSelect(h.paragraph),
            );
          },
        );
      },
    );
  }
}
