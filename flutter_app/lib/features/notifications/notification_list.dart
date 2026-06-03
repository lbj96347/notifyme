import 'package:flutter/material.dart';

import '../../shared/notification_status.dart';
import 'notification_date_group.dart';
import 'notification_detail_screen.dart';
import 'notification_model.dart';
import 'notification_repository.dart';

/// Shared presentation for a day-grouped notification list and its rows.
///
/// Both the inbox and the Bookmarks tab render the same list, so the grouped
/// list, the per-notification tile (including its bookmark toggle), the category
/// chip and the empty state all live here rather than being duplicated per
/// screen. Each tile can toggle its own bookmark state via [repository], scoped
/// to [uid] — mirroring the inbox's mark-read flow — and the change propagates
/// back through whichever Firestore stream the hosting screen is watching.

/// Renders the day-grouped list: a header per day followed by its rows.
class NotificationGroupedList extends StatelessWidget {
  const NotificationGroupedList({
    super.key,
    required this.groups,
    required this.uid,
    required this.repository,
    this.isLoadingMore = false,
    this.loadMoreError = false,
    this.onRetryLoadMore,
    this.hasReachedEnd = false,
    this.canLoadMoreForSearch = false,
    this.onLoadMore,
    this.onChanged,
  });

  final List<NotificationDateGroup> groups;
  final String uid;
  final NotificationRepository repository;

  /// When true, a footer spinner is appended — the cue that the next page is
  /// being fetched as the user scrolls toward the bottom.
  final bool isLoadingMore;

  /// When true, the last attempt to load the next page failed; a footer with a
  /// retry button is shown instead of the spinner. Takes precedence over
  /// [isLoadingMore], [canLoadMoreForSearch] and [hasReachedEnd].
  final bool loadMoreError;

  /// Invoked by the load-more error footer's retry button. Required in practice
  /// whenever [loadMoreError] can be true.
  final VoidCallback? onRetryLoadMore;

  /// When true (and not loading or erroring), a quiet "end of list" footer marks
  /// that every page has been loaded — there's nothing more to fetch.
  final bool hasReachedEnd;

  /// When true, a search is active and more pages remain that haven't been
  /// searched yet (client-side search only sees loaded pages). A "Load more
  /// results" button footer is appended so the user can pull in further pages
  /// to extend the search — a short filtered list often isn't tall enough to
  /// trigger scroll-based auto-loading. Mutually exclusive with [hasReachedEnd],
  /// which is suppressed while searching.
  final bool canLoadMoreForSearch;

  /// Invoked by the "Load more results" search footer. Required in practice
  /// whenever [canLoadMoreForSearch] can be true.
  final VoidCallback? onLoadMore;

  /// Called with a row's id after it changes something the list can't see live
  /// (a bookmark toggle, or the read flip when its detail screen opens), so the
  /// hosting screen can reconcile just that row. Optional — when the list is
  /// backed by a live stream there's nothing to do here.
  final Future<void> Function(String id)? onChanged;

  @override
  Widget build(BuildContext context) {
    // Flatten groups into a single index space: one header item per group
    // followed by its rows, plus an optional trailing footer. This keeps the
    // whole list lazily built by a single ListView rather than nesting
    // scrollables.
    final items = <_ListItem>[];
    for (final group in groups) {
      items.add(_HeaderItem(group.label));
      for (final n in group.notifications) {
        items.add(_RowItem(n));
      }
    }
    // At most one footer, in priority order: a load-more failure (offer a
    // retry) wins over an in-flight spinner, which wins over the search
    // "load more results" prompt, which wins over the end-of-list marker.
    if (loadMoreError) {
      items.add(const _FooterItem(_FooterKind.error));
    } else if (isLoadingMore) {
      items.add(const _FooterItem(_FooterKind.loading));
    } else if (canLoadMoreForSearch) {
      items.add(const _FooterItem(_FooterKind.searchLoadMore));
    } else if (hasReachedEnd) {
      items.add(const _FooterItem(_FooterKind.end));
    }

    return ListView.builder(
      // AlwaysScrollable so a short list can still be pulled to refresh.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        if (item is _HeaderItem) {
          return _DayHeader(label: item.label);
        }
        if (item is _FooterItem) {
          switch (item.kind) {
            case _FooterKind.loading:
              return const _LoadMoreFooter();
            case _FooterKind.error:
              return _LoadMoreErrorFooter(onRetry: onRetryLoadMore);
            case _FooterKind.searchLoadMore:
              return _SearchLoadMoreFooter(onLoadMore: onLoadMore);
            case _FooterKind.end:
              return const _EndOfListFooter();
          }
        }
        return NotificationTile(
          notification: (item as _RowItem).notification,
          uid: uid,
          repository: repository,
          onChanged: onChanged,
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
  const _RowItem(this.notification);
  final AppNotification notification;
}

/// Which trailing footer the list appends: a spinner while the next page loads,
/// a retry prompt after a failed load, a "load more results" prompt to extend a
/// client-side search over further pages, or an end-of-list marker once
/// everything is loaded.
enum _FooterKind { loading, error, searchLoadMore, end }

class _FooterItem extends _ListItem {
  const _FooterItem(this.kind);
  final _FooterKind kind;
}

/// The footer spinner shown while the next page is loading.
class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

/// The footer shown when loading the next page failed: a short message and a
/// retry button. The loaded rows above stay put, so this is a recoverable
/// in-place error rather than a full-screen one.
class _LoadMoreErrorFooter extends StatelessWidget {
  const _LoadMoreErrorFooter({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        children: [
          Text(
            'Couldn’t load more.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// The footer shown during an active search when more pages remain to be
/// loaded. Client-side search only sees pages already fetched, so this lets the
/// user pull in further pages to extend the search — useful when the filtered
/// list is too short to trigger scroll-based auto-loading.
class _SearchLoadMoreFooter extends StatelessWidget {
  const _SearchLoadMoreFooter({this.onLoadMore});

  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        children: [
          Text(
            'Searching loaded notifications only.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onLoadMore,
            icon: const Icon(Icons.expand_more, size: 18),
            label: const Text('Load more results'),
          ),
        ],
      ),
    );
  }
}

/// The quiet end-of-list marker shown once every page has been loaded.
class _EndOfListFooter extends StatelessWidget {
  const _EndOfListFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(
          'You’re all caught up',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
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

/// A single notification row: status rail, title/message, category, time, and a
/// bookmark toggle. Tapping the body opens the detail screen; tapping the
/// bookmark icon stars/unstars the notification.
class NotificationTile extends StatelessWidget {
  const NotificationTile({
    super.key,
    required this.notification,
    required this.uid,
    required this.repository,
    this.onChanged,
  });

  final AppNotification notification;
  final String uid;
  final NotificationRepository repository;

  /// Called with this row's id after it mutates state the host can't observe
  /// live (a bookmark toggle, or the read flip the detail screen performs on
  /// open) so the host can reconcile just this row. Null when the host watches a
  /// live stream instead.
  final Future<void> Function(String id)? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = NotificationStatus.fromWire(notification.status);
    final unread = !notification.read;
    final created = notification.createdAt;

    return Material(
      // Unread rows get a faint tint so the eye lands on them first.
      color: unread ? status.color.withValues(alpha: 0.06) : Colors.transparent,
      child: InkWell(
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  NotificationDetailScreen(notification: notification),
            ),
          );
          // The detail screen marks the notification read on open; reconcile so
          // the row drops its unread styling.
          await onChanged?.call(notification.id);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Status color rail.
              Container(
                width: 4,
                height: 40,
                margin: const EdgeInsets.only(top: 2, right: 12),
                decoration: BoxDecoration(
                  color: status.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            notification.title.isEmpty
                                ? '(no title)'
                                : notification.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: unread
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (unread)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(left: 8, top: 4),
                            decoration: BoxDecoration(
                              color: status.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    if (notification.message.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        notification.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        NotificationCategoryChip(
                          label: notification.category,
                          color: status.color,
                        ),
                        const Spacer(),
                        if (created != null)
                          Text(
                            NotificationDateGroup.formatTime(created),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              _BookmarkButton(
                notification: notification,
                uid: uid,
                repository: repository,
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The star icon on each row. Toggles [AppNotification.bookmarked] via the
/// repository and surfaces a failure as a SnackBar; the row itself refreshes
/// through the hosting screen's live stream, so there's no local state here.
class _BookmarkButton extends StatelessWidget {
  const _BookmarkButton({
    required this.notification,
    required this.uid,
    required this.repository,
    this.onChanged,
  });

  final AppNotification notification;
  final String uid;
  final NotificationRepository repository;
  final Future<void> Function(String id)? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bookmarked = notification.bookmarked;
    return IconButton(
      icon: Icon(
        bookmarked ? Icons.bookmark : Icons.bookmark_border,
        color: bookmarked ? theme.colorScheme.primary : null,
      ),
      tooltip: bookmarked ? 'Remove bookmark' : 'Bookmark',
      onPressed: () => _toggle(context),
    );
  }

  Future<void> _toggle(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repository.setBookmark(
        uid,
        notification.id,
        bookmarked: !notification.bookmarked,
      );
      // Reconcile so the star reflects the new state (the list isn't live).
      await onChanged?.call(notification.id);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn’t update bookmark.')),
      );
    }
  }
}

/// The small pill showing a notification's category, tinted to its status color.
class NotificationCategoryChip extends StatelessWidget {
  const NotificationCategoryChip({
    super.key,
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Centered icon + title + subtitle used for the loading-empty, no-results and
/// error states across notification screens.
class NotificationEmptyState extends StatelessWidget {
  const NotificationEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// Optional action shown below the subtitle — e.g. a "Load more results"
  /// button on the no-matches search state, so an empty result with more pages
  /// still loaded isn't a dead end.
  final Widget? action;

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
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
