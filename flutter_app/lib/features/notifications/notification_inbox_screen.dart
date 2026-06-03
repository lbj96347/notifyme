import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import 'notification_date_group.dart';
import 'notification_inbox_controller.dart';
import 'notification_list.dart';
import 'notification_model.dart';
import 'notification_repository.dart';

/// The notification inbox: a paginated, newest-first list of the signed-in
/// user's notifications, grouped under Today / Yesterday / older-date headers.
///
/// Each row shows the status color, title, message, category, read state and
/// time. The screen drives a [NotificationInboxController] — a pull-based
/// pagination machine over [NotificationRepository.fetchPage]. The first page
/// loads on mount; pull-to-refresh reloads page one (keeping the current list
/// visible) and scrolling near the bottom appends the next page.
///
/// Because the list is pull-based rather than a live stream, the in-inbox
/// mutations that used to update through Firestore snapshots reconcile in place
/// so the loaded pages survive: a per-row change (a bookmark toggle, or the read
/// flip when the detail screen opens) re-reads just that row via
/// [NotificationInboxController.reloadNotification], and mark-all-read flips the
/// loaded rows via [NotificationInboxController.markAllReadLocally]. Neither
/// resets the cursor, so the user keeps the pages they'd scrolled through.
///
/// A toggleable search field filters the loaded notifications client-side by
/// title, message and category. Search is MVP-simple: it runs over whatever
/// pages have already loaded — there's no server-side query or external search
/// service — so while a search is active the inbox offers to load further pages
/// (a footer button, and a "Load more results" action on the no-matches state)
/// and suppresses the "all caught up" end marker, which would otherwise
/// misrepresent the filtered subset as the full result set.
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

  late final NotificationRepository _repository;

  /// The signed-in user's uid, or `null` when signed out. Stored so the actions
  /// (mark-all-read) and the controller can scope to it after mount.
  String? _uid;

  /// Drives the list. `null` only when no user is signed in.
  NotificationInboxController? _controller;

  /// How close to the bottom (in pixels) a scroll must reach before the next
  /// page is requested.
  static const double _loadMoreThreshold = 300;

  @override
  void initState() {
    super.initState();
    _repository = widget._repository ?? NotificationRepository();
    final user = (widget._authService ?? AuthService()).currentUser;
    if (user != null) {
      _uid = user.uid;
      _controller = NotificationInboxController(
        repository: _repository,
        uid: user.uid,
      )..loadInitial();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
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
    final controller = _controller;
    if (controller == null) {
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
                onPressed: () => _markAllRead(controller),
              ),
            ],
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _buildBody(controller),
      ),
    );
  }

  Widget _buildBody(NotificationInboxController controller) {
    // The very first page is still in flight and nothing is on screen yet.
    if (controller.isInitialLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // The first load failed before anything could be shown. Pull-to-refresh is
    // the way back, so the error state stays refreshable.
    if (controller.error != null && controller.notifications.isEmpty) {
      return _refreshable(
        controller,
        const NotificationEmptyState(
          icon: Icons.error_outline,
          title: 'Couldn’t load notifications',
          subtitle: 'Check your connection and pull to try again.',
        ),
      );
    }

    if (controller.isEmpty) {
      return _refreshable(
        controller,
        const NotificationEmptyState(
          icon: Icons.notifications_none,
          title: 'No notifications yet',
          subtitle: 'POST to your webhook URL and it’ll show up here.',
        ),
      );
    }

    final matches = _filter(controller.notifications, _query);
    if (matches.isEmpty) {
      // Client-side search only sees loaded pages. When more remain, "No
      // matches" would be a false negative — the match might be in an unloaded
      // page — so offer to load more instead of declaring nothing matches.
      final canSearchMore = controller.hasMore;
      return _refreshable(
        controller,
        NotificationEmptyState(
          icon: Icons.search_off,
          title: canSearchMore ? 'No matches yet' : 'No matches',
          subtitle: canSearchMore
              ? 'Nothing in the loaded notifications matches '
                    '“${_searchController.text}”. Load more to keep searching.'
              : 'Nothing matches “${_searchController.text}”.',
          action: canSearchMore
              ? OutlinedButton.icon(
                  onPressed: controller.isLoadingMore
                      ? null
                      : controller.loadMore,
                  icon: const Icon(Icons.expand_more, size: 18),
                  label: const Text('Load more results'),
                )
              : null,
        ),
      );
    }

    final groups = NotificationDateGroup.groupByDay(matches);
    return RefreshIndicator(
      onRefresh: () => _refresh(controller),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _maybeLoadMore(notification, controller);
          return false;
        },
        child: NotificationGroupedList(
          groups: groups,
          uid: _uid!,
          repository: _repository,
          isLoadingMore: controller.isLoadingMore,
          loadMoreError: controller.loadMoreError != null,
          onRetryLoadMore: controller.loadMore,
          // Only mark the end of the list when nothing is filtering the view —
          // "all caught up" under a search query would misrepresent the
          // client-side filtered subset as the full result set.
          hasReachedEnd: !controller.hasMore && _query.isEmpty,
          // While searching, offer to pull in further pages: client-side search
          // only sees loaded pages, and a short filtered list may never scroll
          // far enough to auto-load more.
          canLoadMoreForSearch: _query.isNotEmpty && controller.hasMore,
          onLoadMore: controller.loadMore,
          // A change made from a row (bookmark toggle, or the read flip when the
          // detail screen opens) isn't visible on a pull-based list until it's
          // reconciled. Reload just that one row rather than refreshing page one
          // — a refresh would discard the pages already loaded below.
          onChanged: controller.reloadNotification,
        ),
      ),
    );
  }

  /// Wraps a short, otherwise non-scrollable state (error / empty / no-results)
  /// so it can still be pulled to refresh.
  Widget _refreshable(NotificationInboxController controller, Widget child) {
    return RefreshIndicator(
      onRefresh: () => _refresh(controller),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: child,
          ),
        ),
      ),
    );
  }

  /// Requests the next page once the scroll position nears the bottom. The
  /// controller's own guards drop the call when a load is already running, when
  /// there's nothing more to fetch, or before the first page exists, so this can
  /// fire freely during a fling.
  ///
  /// When a previous [NotificationInboxController.loadMore] failed, auto-loading
  /// stops: the user sits at the bottom next to the error footer, where firing
  /// loadMore every scroll frame would retry-storm a persistent failure. The
  /// footer's Retry button is the deliberate way back.
  void _maybeLoadMore(
    ScrollNotification notification,
    NotificationInboxController controller,
  ) {
    if (controller.loadMoreError != null) return;
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return;
    if (metrics.pixels >= metrics.maxScrollExtent - _loadMoreThreshold) {
      controller.loadMore();
    }
  }

  /// Reloads page one for pull-to-refresh. The controller keeps the existing
  /// list visible and, on failure, leaves it intact and sets [error]; this
  /// surfaces that failure as a SnackBar so a silent no-op isn't mistaken for a
  /// successful refresh.
  Future<void> _refresh(NotificationInboxController controller) async {
    await controller.refresh();
    if (!mounted) return;
    if (controller.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t refresh notifications.')),
      );
    }
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

  /// Marks all of the user's unread notifications as read, reloads the list so
  /// the rows reflect it, then reports the outcome via a SnackBar.
  Future<void> _markAllRead(NotificationInboxController controller) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await _repository.markAllRead(_uid!);
      // Flip the loaded rows in place rather than refreshing page one, which
      // would discard the pages already loaded below.
      controller.markAllReadLocally();
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
