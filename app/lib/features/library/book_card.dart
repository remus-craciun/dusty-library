import 'package:flutter/material.dart';

import '../../data/models.dart';

/// Grid tile for a book: a generated "cover", title, author and a progress bar.
class BookCard extends StatelessWidget {
  const BookCard({
    super.key,
    required this.book,
    required this.downloaded,
    required this.onTap,
    required this.onMenu,
  });

  final Book book;
  final bool downloaded;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final percent = (book.progress * 100).round();
    final coverColor = _coverColor(book.title, scheme);

    return Card(
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [coverColor, Color.lerp(coverColor, Colors.black, 0.35)!],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Text(
                          book.title,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            shadows: const [Shadow(blurRadius: 6, color: Colors.black54)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (downloaded)
                          Tooltip(
                            message: 'Available offline',
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
                              child: const Icon(Icons.offline_pin, size: 16, color: Colors.white),
                            ),
                          ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.more_vert, color: Colors.white),
                          style: IconButton.styleFrom(backgroundColor: Colors.black38),
                          onPressed: onMenu,
                          tooltip: 'Book actions',
                        ),
                      ],
                    ),
                  ),
                  if (book.isFinished)
                    const Positioned(
                      top: 8,
                      left: 8,
                      child: Icon(Icons.check_circle, color: Colors.white, size: 20),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.author.isEmpty ? 'Unknown author' : book.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: book.progress,
                      minHeight: 6,
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    book.pageCount > 0
                        ? '$percent%  ·  ${book.currentPage.clamp(0, book.pageCount)} / ${book.pageCount} pages'
                        : 'Not opened yet',
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _coverColor(String title, ColorScheme scheme) {
    final palette = [
      const Color(0xFF8B5E3C),
      const Color(0xFF5C6B4A),
      const Color(0xFF4A5A7A),
      const Color(0xFF7A4A5A),
      const Color(0xFF6B5A3C),
      const Color(0xFF3C6B6B),
    ];
    return palette[title.hashCode.abs() % palette.length];
  }
}
