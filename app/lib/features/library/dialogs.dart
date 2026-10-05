import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../data/models.dart';
import 'library_providers.dart';

String describeError(Object e) => switch (e) {
  NetworkException(:final message) => 'Offline: $message',
  ApiException(:final message) => message,
  _ => e.toString(),
};

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(describeError(e))));
}

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? initial,
  String label = 'Name',
  String confirm = 'Save',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        textInputAction: TextInputAction.done,
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: Text(confirm)),
      ],
    ),
  ).then((v) => (v == null || v.isEmpty) ? null : v);
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  bool destructive = true,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return res ?? false;
}

/// Lets the user pick a destination shelf for [book].
Future<void> showMoveToShelf(BuildContext context, WidgetRef ref, Book book) async {
  final data = ref.read(libraryProvider).asData?.value;
  if (data == null) return;
  final target = await showModalBottomSheet<Shelf>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Move "${book.title}" to', style: Theme.of(ctx).textTheme.titleMedium),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final s in data.shelves)
                  ListTile(
                    leading: Icon(_shelfIcon(s.kind)),
                    title: Text(s.name),
                    trailing: s.id == book.shelfId ? const Icon(Icons.check) : null,
                    enabled: s.id != book.shelfId,
                    onTap: () => Navigator.pop(ctx, s),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (target == null || !context.mounted) return;
  try {
    await ref.read(libraryProvider.notifier).moveBook(book, target.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Moved to ${target.name}')));
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

IconData _shelfIcon(ShelfKind kind) => switch (kind) {
  ShelfKind.active => Icons.auto_stories_outlined,
  ShelfKind.completed => Icons.task_alt,
  ShelfKind.custom => Icons.shelves,
};

IconData shelfIcon(ShelfKind kind) => _shelfIcon(kind);

/// Create / rename / delete custom shelves.
Future<void> showManageShelves(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => const _ManageShelvesSheet(),
  );
}

class _ManageShelvesSheet extends ConsumerWidget {
  const _ManageShelvesSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(libraryProvider).asData?.value;
    final shelves = data?.shelves ?? const <Shelf>[];
    final notifier = ref.read(libraryProvider.notifier);
    final theme = Theme.of(context);

    Future<void> run(Future<void> Function() f) async {
      try {
        await f();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(child: Text('Shelves', style: theme.textTheme.titleLarge)),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final name = await promptText(context, title: 'New shelf', confirm: 'Create');
                      if (name != null) await run(() => notifier.createShelf(name));
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('New shelf'),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in shelves)
                    ListTile(
                      leading: Icon(_shelfIcon(s.kind)),
                      title: Text(s.name),
                      subtitle: Text(
                        s.isPredefined
                            ? 'Built-in shelf'
                            : '${data?.booksOn(s.id).length ?? 0} book(s)',
                      ),
                      trailing: s.isPredefined
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Rename',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () async {
                                    final name = await promptText(context, title: 'Rename shelf', initial: s.name);
                                    if (name != null && name != s.name) {
                                      await run(() => notifier.renameShelf(s.id, name));
                                    }
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Delete',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    final ok = await confirm(
                                      context,
                                      title: 'Delete "${s.name}"?',
                                      message: 'Books on this shelf will be moved back to Active.',
                                    );
                                    if (ok) await run(() => notifier.deleteShelf(s.id));
                                  },
                                ),
                              ],
                            ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Context menu for a single book.
Future<void> showBookMenu(BuildContext context, WidgetRef ref, Book book, {required bool downloaded}) async {
  final notifier = ref.read(libraryProvider.notifier);
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(book.title, style: Theme.of(ctx).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(book.author.isEmpty ? _size(book.sizeBytes) : '${book.author} · ${_size(book.sizeBytes)}'),
          ),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.drive_file_move_outline), title: const Text('Move to shelf'), onTap: () => Navigator.pop(ctx, 'move')),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Edit title / author'), onTap: () => Navigator.pop(ctx, 'edit')),
          if (downloaded)
            ListTile(leading: const Icon(Icons.cloud_off_outlined), title: const Text('Remove offline copy'), onTap: () => Navigator.pop(ctx, 'undownload'))
          else
            ListTile(leading: const Icon(Icons.download_outlined), title: const Text('Download for offline reading'), onTap: () => Navigator.pop(ctx, 'download')),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
            title: Text('Delete book', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;

  try {
    switch (action) {
      case 'move':
        await showMoveToShelf(context, ref, book);
      case 'edit':
        await editBookDetails(context, ref, book);
      case 'download':
        await _downloadWithProgress(context, ref, book);
      case 'undownload':
        await notifier.removeDownload(book);
      case 'delete':
        final ok = await confirm(
          context,
          title: 'Delete "${book.title}"?',
          message: 'The PDF and your reading progress will be removed from the server.',
        );
        if (ok) await notifier.deleteBook(book);
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Title and author entered by the user.
typedef BookDetails = ({String title, String author});

/// Form for a book's title and author. Returns null when cancelled.
Future<BookDetails?> showBookDetailsDialog(
  BuildContext context, {
  required String heading,
  required String confirm,
  String title = '',
  String author = '',
  String? subtitle,
}) {
  final titleCtl = TextEditingController(text: title);
  final authorCtl = TextEditingController(text: author);
  final formKey = GlobalKey<FormState>();
  return showDialog<BookDetails>(
    context: context,
    builder: (ctx) {
      void submit() {
        if (!formKey.currentState!.validate()) return;
        Navigator.pop(ctx, (title: titleCtl.text.trim(), author: authorCtl.text.trim()));
      }

      return AlertDialog(
        title: Text(heading),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (subtitle != null) ...[
                Text(subtitle, style: Theme.of(ctx).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: titleCtl,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                maxLength: 200,
                decoration: const InputDecoration(labelText: 'Title', prefixIcon: Icon(Icons.title), counterText: ''),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Title is required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: authorCtl,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                maxLength: 120,
                onFieldSubmitted: (_) => submit(),
                decoration: const InputDecoration(labelText: 'Author', prefixIcon: Icon(Icons.person_outline), counterText: ''),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: Text(confirm)),
        ],
      );
    },
  );
}

/// Opens the details form for an existing book and saves changes.
Future<void> editBookDetails(BuildContext context, WidgetRef ref, Book book) async {
  final res = await showBookDetailsDialog(
    context,
    heading: 'Edit book',
    confirm: 'Save',
    title: book.title,
    author: book.author,
  );
  if (res == null || !context.mounted) return;
  if (res.title == book.title && res.author == book.author) return;
  try {
    await ref.read(libraryProvider.notifier).renameBook(book, res.title, res.author);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Book details saved')));
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> _downloadWithProgress(BuildContext context, WidgetRef ref, Book book) async {
  final progress = ValueNotifier<double>(0);
  final future = ref.read(libraryProvider.notifier).download(book, onProgress: (p) => progress.value = p);
  await showProgressDialog(context, title: 'Downloading "${book.title}"', progress: progress, future: future);
}

/// Modal progress dialog that closes itself when [future] completes.
Future<T> showProgressDialog<T>(
  BuildContext context, {
  required String title,
  required ValueListenable<double> progress,
  required Future<T> future,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var closed = false;
  // ignore: unawaited_futures
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v > 0 ? v : null),
              const SizedBox(height: 8),
              Text(v > 0 ? '${(v * 100).round()}%' : 'Please wait…'),
            ],
          ),
        ),
      ),
    ),
  ).whenComplete(() => closed = true);
  try {
    return await future;
  } finally {
    if (!closed && navigator.mounted) navigator.pop();
  }
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
