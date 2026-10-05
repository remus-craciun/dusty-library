import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/server_config.dart';
import '../../core/session.dart';
import '../../data/library_repository.dart';
import '../../data/models.dart';
import 'book_card.dart';
import 'dialogs.dart';
import 'library_providers.dart';
import 'library_query.dart';
import 'picker_options_stub.dart'
    if (dart.library.js_interop) 'picker_options_web.dart';
import 'upload_dialog.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  static const _wideBreakpoint = 840.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final selection = ref.watch(selectedShelfProvider);
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final data = library.asData?.value;
    // The app opens on the Active shelf; after that the user's choice sticks.
    final selected = selection.explicit
        ? selection.id
        : data?.shelfOfKind(ShelfKind.active)?.id;
    final shelfName = selected == null
        ? 'All books'
        : data?.shelves.where((s) => s.id == selected).firstOrNull?.name ??
              'Shelf';

    final body = switch (library) {
      AsyncData(:final value) => _BookGrid(data: value, shelfId: selected),
      AsyncError(:final error) => _ErrorView(error: error),
      _ => const Center(child: CircularProgressIndicator()),
    };

    final shelfPanel = data == null
        ? null
        : _ShelfPanel(data: data, selected: selected);

    return Scaffold(
      appBar: AppBar(
        title: Text(shelfName),
        actions: [
          if (data?.offline == true)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Tooltip(
                message: 'Offline: showing cached library',
                child: Icon(Icons.cloud_off),
              ),
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref
                .read(libraryProvider.notifier)
                .refresh()
                .catchError((Object e) {
                  if (context.mounted) showError(context, e);
                }),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'shelves':
                  await showManageShelves(context, ref);
                case 'server':
                  await ref.read(sessionProvider.notifier).signOut();
                  await ref.read(serverUrlProvider.notifier).clear();
                case 'logout':
                  final ok = await confirm(
                    context,
                    title: 'Sign out?',
                    message: 'Downloaded books on this device will be removed.',
                    confirmLabel: 'Sign out',
                  );
                  if (ok) await ref.read(sessionProvider.notifier).signOut();
                case 'logout_all':
                  final ok = await confirm(
                    context,
                    title: 'Sign out everywhere?',
                    message: 'Every device signed in to this account will have to log in again.',
                    confirmLabel: 'Sign out everywhere',
                  );
                  if (ok) {
                    await ref
                        .read(sessionProvider.notifier)
                        .signOut(everywhere: true);
                  }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'shelves',
                child: ListTile(
                  leading: Icon(Icons.shelves),
                  title: Text('Manage shelves'),
                ),
              ),
              if (!kIsWeb)
                const PopupMenuItem(
                  value: 'server',
                  child: ListTile(
                    leading: Icon(Icons.dns_outlined),
                    title: Text('Change server'),
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Sign out'),
                ),
              ),
              const PopupMenuItem(
                value: 'logout_all',
                child: ListTile(
                  leading: Icon(Icons.devices_other),
                  title: Text('Sign out everywhere'),
                ),
              ),
            ],
          ),
        ],
      ),
      drawer: wide || shelfPanel == null
          ? null
          : Drawer(child: SafeArea(child: shelfPanel)),
      body: Column(
        children: [
          if (data?.offline == true) _OfflineBanner(data: data!),
          Expanded(
            child: wide && shelfPanel != null
                ? Row(
                    children: [
                      SizedBox(
                        width: 260,
                        child: Material(elevation: 1, child: shelfPanel),
                      ),
                      Expanded(child: body),
                    ],
                  )
                : body,
          ),
        ],
      ),
      floatingActionButton: data == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _pickAndUpload(context, ref, data, selected),
              icon: const Icon(Icons.add),
              label: const Text('Add book'),
            ),
    );
  }

  Future<void> _pickAndUpload(
    BuildContext context,
    WidgetRef ref,
    LibraryData data,
    int? shelfId,
  ) async {
    if (data.offline) {
      showError(context, NetworkException('cannot upload while offline'));
      return;
    }
    List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        dialogTitle: 'Choose a PDF',
        webOptions: pickerWebOptions(),
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
      return;
    }
    if (files.isEmpty || !context.mounted) return;
    final file = files.first;

    // Let the user name the book before it goes up; the file name is a hint.
    final details = await showBookDetailsDialog(
      context,
      heading: 'Add book',
      confirm: 'Upload',
      title: titleFromFilename(file.name),
      subtitle: file.name,
    );
    if (details == null || !context.mounted) return;

    final progress = UploadProgress();
    final future = () async {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) throw StateError('The selected file is empty.');
      return ref
          .read(libraryProvider.notifier)
          .upload(
            filename: file.name,
            bytes: bytes,
            title: details.title,
            author: details.author,
            shelfId: shelfId ?? data.shelfOfKind(ShelfKind.active)?.id,
            progress: progress,
          );
    }();
    try {
      final book = await showUploadDialog(
        context,
        filename: file.name,
        progress: progress,
        future: future,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added "${book.title}"'),
            action: SnackBarAction(
              label: 'Read',
              onPressed: () => context.push(Routes.reader(book.id)),
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

class _ShelfPanel extends ConsumerWidget {
  const _ShelfPanel({required this.data, required this.selected});
  final LibraryData data;
  final int? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);

    void choose(int? id) {
      ref.read(selectedShelfProvider.notifier).select(id);
      final scaffold = Scaffold.maybeOf(context);
      if (scaffold?.isDrawerOpen == true) Navigator.pop(context);
    }

    Widget tile(String name, IconData icon, int? id, int count) => ListTile(
      leading: Icon(icon),
      title: Text(name),
      trailing: Text('$count', style: theme.textTheme.labelMedium),
      selected: selected == id,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      onTap: () => choose(id),
    );

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Icon(
                Icons.local_library_outlined,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Dusty Library', style: theme.textTheme.titleMedium),
                    if (session.username != null)
                      Text(
                        session.username!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        tile('All books', Icons.menu_book_outlined, null, data.books.length),
        const Divider(),
        for (final s in data.shelves.where((s) => s.isPredefined))
          tile(s.name, shelfIcon(s.kind), s.id, data.booksOn(s.id).length),
        if (data.shelves.any((s) => !s.isPredefined)) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'My shelves',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          for (final s in data.shelves.where((s) => !s.isPredefined))
            tile(s.name, shelfIcon(s.kind), s.id, data.booksOn(s.id).length),
        ],
        const Divider(),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('Manage shelves'),
          onTap: () {
            if (Scaffold.maybeOf(context)?.isDrawerOpen == true) {
              Navigator.pop(context);
            }
            showManageShelves(context, ref);
          },
        ),
      ],
    );
  }
}

class _BookGrid extends ConsumerStatefulWidget {
  const _BookGrid({required this.data, required this.shelfId});
  final LibraryData data;
  final int? shelfId;

  @override
  ConsumerState<_BookGrid> createState() => _BookGridState();
}

class _BookGridState extends ConsumerState<_BookGrid> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(Book book) {
    final data = widget.data;
    if (data.offline && !data.downloaded.contains(book.id)) {
      showError(context, NetworkException('this book is not downloaded'));
      return;
    }
    context.push(Routes.reader(book.id));
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final onShelf = data.booksOn(widget.shelfId);
    if (onShelf.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories_outlined,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('No books here yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Use "Add book" to upload a PDF.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    final query = _query.text;
    final books = onShelf.where((b) => bookMatchesQuery(b, query)).toList();
    final resume = query.trim().isEmpty ? continueReading(onShelf) : null;
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search title or author',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        _query.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close),
                    ),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (resume != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Material(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: Icon(
                  Icons.auto_stories,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                title: Text(
                  resume.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_continueLabel(resume)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(resume),
              ),
            ),
          ),
        Expanded(
          child: books.isEmpty
              ? Center(
                  child: Text(
                    'No books match “${query.trim()}”',
                    style: theme.textTheme.titleMedium,
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => ref
                      .read(libraryProvider.notifier)
                      .refresh()
                      .catchError((Object e) {
                        if (context.mounted) showError(context, e);
                      }),
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 200,
                          mainAxisExtent: 270,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                    itemCount: books.length,
                    itemBuilder: (context, i) {
                      final book = books[i];
                      final downloaded = data.downloaded.contains(book.id);
                      return _CardEntry(
                        key: ValueKey(book.id),
                        delay: Duration(milliseconds: 40 * math.min(i, 10)),
                        child: BookCard(
                          book: book,
                          downloaded: downloaded,
                          onTap: () => _open(book),
                          onMenu: () => showBookMenu(
                            context,
                            ref,
                            book,
                            downloaded: downloaded,
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

String _continueLabel(Book book) {
  final page = book.currentPage < 1 ? 1 : book.currentPage;
  if (book.pageCount > 0) return 'Continue · page $page of ${book.pageCount}';
  return 'Continue · page $page';
}

/// Fades and scales a card in when it first appears (new upload, first load).
class _CardEntry extends StatefulWidget {
  const _CardEntry({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });
  final Widget child;
  final Duration delay;

  @override
  State<_CardEntry> createState() => _CardEntryState();
}

class _CardEntryState extends State<_CardEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final Animation<double> _scale = Tween(
    begin: 0.88,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutBack));
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOut,
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: ScaleTransition(scale: _scale, child: widget.child),
  );
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.data});
  final LibraryData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pending = data.pendingCount;
    return Material(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 18, color: scheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                pending > 0
                    ? 'Offline. $pending progress update(s) will sync when the server is reachable.'
                    : 'Offline. Showing your cached library; only downloaded books can be opened.',
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends ConsumerWidget {
  const _ErrorView({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              'Could not load your library',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              describeError(error),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => ref.invalidate(libraryProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
