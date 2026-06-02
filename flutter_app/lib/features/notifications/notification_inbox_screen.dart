import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import 'notification_date_group.dart';
import 'notification_list.dart';
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
        body: NotificationEmptyState(
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
            return const NotificationEmptyState(
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
            return const NotificationEmptyState(
              icon: Icons.notifications_none,
              title: 'No notifications yet',
              subtitle: 'POST to your webhook URL and it’ll show up here.',
            );
          }

          final matches = _filter(notifications, _query);
          if (matches.isEmpty) {
            return NotificationEmptyState(
              icon: Icons.search_off,
              title: 'No matches',
              subtitle: 'Nothing matches “${_searchController.text}”.',
            );
          }

          final groups = NotificationDateGroup.groupByDay(matches);
          return NotificationGroupedList(
            groups: groups,
            uid: user.uid,
            repository: repository,
          );
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
