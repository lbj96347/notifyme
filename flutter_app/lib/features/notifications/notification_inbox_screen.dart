import 'package:flutter/material.dart';

import '../../shared/notification_status.dart';
import '../auth/auth_service.dart';
import 'notification_date_group.dart';
import 'notification_detail_screen.dart';
import 'notification_model.dart';
import 'notification_repository.dart';

/// The notification inbox: a live, newest-first list of the signed-in user's
/// notifications, grouped under Today / Yesterday / older-date headers.
///
/// Each row shows the status color, title, message, category, read state and
/// time. The screen is read-only here — it owns no Firestore knowledge beyond
/// asking [NotificationRepository] for a stream scoped to the current `uid`.
///
/// A toggleable search field lets the user filter the loaded notifications
/// client-side by title, message and category. Search is MVP-simple: it runs
/// over whatever the live stream has already delivered — there's no server-side
/// query or external search service.
class NotificationInboxScreen extends StatefulWidget {
  const NotificationInboxScreen({
    super.key,
    NotificationRepository? repository,
    AuthService? authService,
  }) : _repository = repository,
       _authService = authService;

  final NotificationRepository? _repository;
  final AuthService? _authService;

  @override
  State<NotificationInboxScreen> createState() =>
      _NotificationInboxScreenState();
}

class _NotificationInboxScreenState extends State<NotificationInboxScreen> {
  final TextEditingController _searchController = TextEditingController();

  /// The current search text, lower-cased. Empty means "no filter".
  String _query = '';

  /// Whether the search field is showing in place of the title.
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openSearch() => setState(() => _searching = true);

  void _closeSearch() {
    _searchController.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final repository = widget._repository ?? NotificationRepository();
    final user = (widget._authService ?? AuthService()).currentUser;

    if (user == null) {
      return const _InboxScaffold(
        body: _EmptyState(
          icon: Icons.lock_outline,
          title: 'Not signed in',
          subtitle: 'Sign in to see your notifications.',
        ),
      );
    }

    return _InboxScaffold(
      title: _searching
          ? _SearchField(
              controller: _searchController,
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            )
          : null,
      actions: _searching
          ? [
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close search',
                onPressed: _closeSearch,
              ),
            ]
          : [
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Search',
                onPressed: _openSearch,
              ),
              IconButton(
                icon: const Icon(Icons.done_all),
                tooltip: 'Mark all read',
                onPressed: () => _markAllRead(context, repository, user.uid),
              ),
            ],
      body: StreamBuilder<List<AppNotification>>(
        stream: repository.watchForUser(user.uid),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const _EmptyState(
              icon: Icons.error_outline,
              title: 'Couldn’t load notifications',
              subtitle: 'Check your connection and try again.',
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final notifications = snapshot.data ?? const <AppNotification>[];
          if (notifications.isEmpty) {
            return const _EmptyState(
              icon: Icons.notifications_none,
              title: 'No notifications yet',
              subtitle: 'POST to your webhook URL and it’ll show up here.',
            );
          }

          final matches = _filter(notifications, _query);
          if (matches.isEmpty) {
            return _EmptyState(
              icon: Icons.search_off,
              title: 'No matches',
              subtitle: 'Nothing matches “${_searchController.text}”.',
            );
          }

          final groups = NotificationDateGroup.groupByDay(matches);
          return _GroupedInboxList(groups: groups);
        },
      ),
    );
  }

  /// Filters [notifications] by a case-insensitive substring match over the
  /// title, message and category. An empty [query] returns the list unchanged.
  List<AppNotification> _filter(
    List<AppNotification> notifications,
    String query,
  ) {
    if (query.isEmpty) {
      return notifications;
    }
    return notifications
        .where(
          (n) =>
              n.title.toLowerCase().contains(query) ||
              n.message.toLowerCase().contains(query) ||
              n.category.toLowerCase().contains(query),
        )
        .toList();
  }

  /// Marks all of the user's unread notifications as read, then reports the
  /// outcome via a SnackBar. The inbox refreshes itself through the live
  /// Firestore stream, so there's no local state to update here.
  Future<void> _markAllRead(
    BuildContext context,
    NotificationRepository repository,
    String uid,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await repository.markAllRead(uid);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            count == 0
                ? 'No unread notifications.'
                : 'Marked $count notification${count == 1 ? '' : 's'} read.',
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn’t mark notifications read.')),
      );
    }
  }
}

/// The AppBar search input shown while [_NotificationInboxScreenState._searching]
/// is true. Autofocuses so the keyboard opens immediately on tap.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autofocus: true,
      textInputAction: TextInputAction.search,
      style: theme.textTheme.titleMedium,
      decoration: const InputDecoration(
        hintText: 'Search notifications',
        border: InputBorder.none,
      ),
    );
  }
}

/// Shared chrome so the loading, empty, error and populated states all sit
/// under the same app bar.
class _InboxScaffold extends StatelessWidget {
  const _InboxScaffold({required this.body, this.actions, this.title});

  final Widget body;
  final List<Widget>? actions;

  /// Replaces the default "Notifications" title — used to swap in the search
  /// field while searching.
  final Widget? title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: title ?? const Text('Notifications'),
        actions: actions,
      ),
      body: body,
    );
  }
}

/// Renders the day-grouped list: a sticky-feeling header per day followed by
/// its notification rows.
class _GroupedInboxList extends StatelessWidget {
  const _GroupedInboxList({required this.groups});

  final List<NotificationDateGroup> groups;

  @override
  Widget build(BuildContext context) {
    // Flatten groups into a single index space: one header item per group
    // followed by its rows. This keeps the whole inbox lazily built by a
    // single ListView rather than nesting scrollables.
    final items = <_InboxItem>[];
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
        return _NotificationTile(notification: (item as _RowItem).notification);
      },
    );
  }
}

/// Marker types for the flattened header/row list.
abstract class _InboxItem {
  const _InboxItem();
}

class _HeaderItem extends _InboxItem {
  const _HeaderItem(this.label);
  final String label;
}

class _RowItem extends _InboxItem {
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

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification});

  final AppNotification notification;

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
                        _CategoryChip(
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
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, required this.color});

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

class _EmptyState extends StatelessWidget {
  const _EmptyState({
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
