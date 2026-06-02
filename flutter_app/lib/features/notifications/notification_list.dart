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
  });

  final List<NotificationDateGroup> groups;
  final String uid;
  final NotificationRepository repository;

  @override
  Widget build(BuildContext context) {
    // Flatten groups into a single index space: one header item per group
    // followed by its rows. This keeps the whole list lazily built by a single
    // ListView rather than nesting scrollables.
    final items = <_ListItem>[];
    for (final group in groups) {
      items.add(_HeaderItem(group.label));
      for (final n in group.notifications) {
        items.add(_RowItem(n));
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
        return NotificationTile(
          notification: (item as _RowItem).notification,
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
  const _RowItem(this.notification);
  final AppNotification notification;
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
  });

  final AppNotification notification;
  final String uid;
  final NotificationRepository repository;

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
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                NotificationDetailScreen(notification: notification),
          ),
        ),
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
  });

  final AppNotification notification;
  final String uid;
  final NotificationRepository repository;

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
