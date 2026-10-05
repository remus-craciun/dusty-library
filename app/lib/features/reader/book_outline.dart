import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// One row of a PDF outline, flattened so a list can indent it.
class OutlineEntry {
  const OutlineEntry({
    required this.title,
    required this.depth,
    this.pageNumber,
  });

  final String title;
  final int depth;

  /// 1-based page, when the outline item points at one.
  final int? pageNumber;
}

/// Walks [nodes] depth-first. Blank titles become "Untitled".
List<OutlineEntry> flattenOutline(List<PdfOutlineNode> nodes, [int depth = 0]) {
  final out = <OutlineEntry>[];
  for (final node in nodes) {
    final title = node.title.trim();
    final page = node.dest?.pageNumber;
    out.add(
      OutlineEntry(
        title: title.isEmpty ? 'Untitled' : title,
        depth: depth,
        pageNumber: page != null && page >= 1 ? page : null,
      ),
    );
    out.addAll(flattenOutline(node.children, depth + 1));
  }
  return out;
}

/// Reads the document outline. The document is closed before this returns.
Future<List<PdfOutlineNode>> loadOutline(
  Uint8List bytes, {
  required String sourceName,
}) async {
  final doc = await PdfDocument.openData(bytes, sourceName: sourceName);
  try {
    return await doc.loadOutline();
  } finally {
    await doc.dispose();
  }
}

/// Scrollable contents list. Tapping a row that has a page calls [onSelect].
class OutlineSheet extends StatelessWidget {
  const OutlineSheet({super.key, required this.nodes, required this.onSelect});

  final List<PdfOutlineNode> nodes;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final entries = flattenOutline(nodes);
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (context, scroll) {
        if (entries.isEmpty) {
          return ListView(
            controller: scroll,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Text(
                  'This book has no table of contents.',
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ],
          );
        }
        return ListView.builder(
          controller: scroll,
          itemCount: entries.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Contents', style: theme.textTheme.titleMedium),
              );
            }
            final entry = entries[i - 1];
            return ListTile(
              contentPadding: EdgeInsets.only(
                left: 16.0 + entry.depth * 16,
                right: 16,
              ),
              title: Text(
                entry.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: entry.pageNumber == null
                  ? null
                  : Text(
                      '${entry.pageNumber}',
                      style: theme.textTheme.labelLarge,
                    ),
              onTap: entry.pageNumber == null
                  ? null
                  : () => onSelect(entry.pageNumber!),
            );
          },
        );
      },
    );
  }
}
