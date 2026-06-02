import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/bookmark.dart';
import '../models/bookmark_day_group.dart';
import '../models/bookmark_url.dart';
import '../repository/bookmark_repository.dart';

/// Presentation for the day-grouped bookmarks list and its rows.
///
/// The Bookmarks tab renders saved links: each row shows the title, the link
/// itself, the time it was saved, and — once revisited — when it was last
/// checked. Tapping the body opens the link in an in-app browser view (and
/// stamps `lastCheckedAt`); the trailing
/// overflow menu edits the title/url or deletes
/// the bookmark via [BookmarkRepository], scoped to [uid]. Every change
/// propagates back through the Firestore stream the screen is watching, so the
/// rows hold no local state.

/// Renders the day-grouped list: a header per day followed by its rows.
class BookmarkGroupedList extends StatelessWidget {
  const BookmarkGroupedList({
    super.key,
    required this.groups,
    required this.uid,
    required this.repository,
  });

  final List<BookmarkDayGroup> groups;
  final String uid;
  final BookmarkRepository repository;

  @override
  Widget build(BuildContext context) {
    // Flatten groups into a single index space: one header item per group
    // followed by its rows. This keeps the whole list lazily built by a single
    // ListView rather than nesting scrollables.
    final items = <_ListItem>[];
    for (final group in groups) {
      items.add(_HeaderItem(group.label));
      for (final b in group.bookmarks) {
        items.add(_RowItem(b));
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        if (item is _HeaderItem) {
          return _DayHeader(label: item.label);
        }
        return BookmarkTile(
          bookmark: (item as _RowItem).bookmark,
          uid: uid,
          repository: repository,
        );
      },
    );
  }
}

/// Marker types for the flattened header/row list.
abstract class _ListItem {
  const _ListItem();
}

class _HeaderItem extends _ListItem {
  const _HeaderItem(this.label);
  final String label;
}

class _RowItem extends _ListItem {
  const _RowItem(this.bookmark);
  final Bookmark bookmark;
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// A single saved-link row: a link icon, the title and URL, the saved time, the
/// last-checked time (once revisited), and an overflow menu to edit or delete.
/// Tapping the body opens the link in an in-app browser view.
class BookmarkTile extends StatelessWidget {
  const BookmarkTile({
    super.key,
    required this.bookmark,
    required this.uid,
    required this.repository,
  });

  final Bookmark bookmark;
  final String uid;
  final BookmarkRepository repository;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = bookmark.createdAt;
    final lastChecked = bookmark.lastCheckedAt;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 12),
                child: Icon(
                  Icons.link,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bookmark.title.isEmpty ? '(no title)' : bookmark.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (bookmark.url.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        bookmark.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                    if (created != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Saved ${BookmarkDayGroup.formatTime(created)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (lastChecked != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Last checked '
                        '${BookmarkDayGroup.formatStamp(lastChecked)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              BookmarkActionsMenu(
                bookmark: bookmark,
                uid: uid,
                repository: repository,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the bookmark's link in an in-app browser view, stamping
  /// `lastCheckedAt`, and surfaces a SnackBar if the URL is malformed or can't
  /// be opened.
  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final trimmed = bookmark.url.trim();
    if (!isValidBookmarkUrl(trimmed)) {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn’t open ${bookmark.url}')),
      );
      return;
    }
    // Best-effort: record the visit. Failure here shouldn't block the user.
    try {
      await repository.touchLastChecked(uid, bookmark.id);
    } catch (_) {
      // Ignore — opening the link is what the user asked for.
    }
    var launched = false;
    final uri = Uri.tryParse(trimmed);
    if (uri != null) {
      launched = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
    if (!launched) {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn’t open ${bookmark.url}')),
      );
    }
  }
}

/// The trailing overflow menu on each row, exposing Edit and Delete.
///
/// Edit opens [BookmarkEditDialog] to change the title/url; Delete asks for
/// confirmation first (the action is destructive and the live stream removes
/// the row immediately, so there'd otherwise be no undo). Both write through the
/// repository, scoped to [uid]; the row updates or disappears via the hosting
/// screen's live stream, so there's no local state here.
class BookmarkActionsMenu extends StatelessWidget {
  const BookmarkActionsMenu({
    super.key,
    required this.bookmark,
    required this.uid,
    required this.repository,
  });

  final Bookmark bookmark;
  final String uid;
  final BookmarkRepository repository;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<_BookmarkAction>(
      icon: Icon(Icons.more_vert, color: theme.colorScheme.outline),
      tooltip: 'Bookmark actions',
      onSelected: (action) {
        switch (action) {
          case _BookmarkAction.edit:
            _edit(context);
          case _BookmarkAction.delete:
            _delete(context);
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _BookmarkAction.edit,
          child: ListTile(
            leading: Icon(Icons.edit_outlined),
            title: Text('Edit'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: _BookmarkAction.delete,
          child: ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Delete'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<({String title, String url})>(
      context: context,
      builder: (_) => BookmarkEditDialog(bookmark: bookmark),
    );
    if (result == null) return; // Cancelled.
    try {
      await repository.update(
        uid,
        bookmark.id,
        title: result.title,
        url: result.url,
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn’t save changes.')),
      );
    }
  }

  Future<void> _delete(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete bookmark?'),
        content: Text(bookmark.title.isEmpty ? bookmark.url : bookmark.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await repository.delete(uid, bookmark.id);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn’t delete bookmark.')),
      );
    }
  }
}

enum _BookmarkAction { edit, delete }

/// A modal dialog for creating or editing a bookmark's title and url.
///
/// Pass an existing [bookmark] to edit it (fields pre-filled, "Edit bookmark"
/// chrome) or omit it to create a new one (empty fields, "Add bookmark"). Pops
/// with a `(title, url)` record on save (trimmed; url required, title optional)
/// or `null` on cancel — it does no Firestore work itself, leaving the write to
/// the caller so this stays a pure input form.
class BookmarkEditDialog extends StatefulWidget {
  const BookmarkEditDialog({super.key, this.bookmark});

  /// The bookmark being edited, or `null` when creating a new one.
  final Bookmark? bookmark;

  @override
  State<BookmarkEditDialog> createState() => _BookmarkEditDialogState();
}

class _BookmarkEditDialogState extends State<BookmarkEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _urlController;

  bool get _isEditing => widget.bookmark != null;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.bookmark?.title ?? '',
    );
    _urlController = TextEditingController(text: widget.bookmark?.url ?? '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop((
      title: _titleController.text.trim(),
      url: _urlController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? 'Edit bookmark' : 'Add bookmark'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(labelText: 'Title (optional)'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'URL'),
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return 'Enter a URL';
                if (!isValidBookmarkUrl(text)) {
                  return 'Enter a valid URL (including https://)';
                }
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(_isEditing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

/// Centered icon + title + subtitle used for the signed-out, loading-empty,
/// empty and error states on the Bookmarks tab.
class BookmarkEmptyState extends StatelessWidget {
  const BookmarkEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
