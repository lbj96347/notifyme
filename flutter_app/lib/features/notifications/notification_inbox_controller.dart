import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../widget/home_widget_service.dart';
import 'notification_model.dart';
import 'notification_repository.dart';

/// Drives the paginated (infinite-scroll) inbox on top of
/// [NotificationRepository.fetchPage].
///
/// A [ChangeNotifier] rather than a `StreamBuilder`: pagination is pull-based
/// (the user scrolls to ask for more), so the screen owns an accumulating list
/// and a cursor instead of re-deriving everything from a live snapshot. The
/// controller holds:
///
/// - [notifications] — every row loaded so far, newest-first, across all pages.
/// - [hasMore] — whether another page exists (mirrors the last page's
///   [NotificationPage.hasMore]); when `false` the UI hides its "load more"
///   affordance.
/// - [isInitialLoading] — the very first page is in flight and nothing is shown
///   yet (full-screen spinner).
/// - [isRefreshing] — a pull-to-refresh is replacing page one while the
///   existing list stays visible.
/// - [isLoadingMore] — a subsequent page is in flight (footer spinner).
/// - [error] — the last load failure, or `null`. It is cleared at the start of
///   each load so a retry starts clean.
/// - [loadMoreError] — the last [loadMore] failure specifically, or `null`. Kept
///   apart from [error] so the list footer can offer an inline retry while the
///   loaded rows stay visible.
///
/// The private `_cursor` is the opaque [DocumentSnapshot] from the last page;
/// the controller passes it straight back to [NotificationRepository.fetchPage]
/// and never inspects it.
///
/// All loads guard against overlap: only one of initial/refresh/load-more runs
/// at a time, so a fling that fires [loadMore] repeatedly — or a [loadMore] that
/// lands during a [refresh] — issues just one query. See [_isBusy].
class NotificationInboxController extends ChangeNotifier {
  NotificationInboxController({
    required NotificationRepository repository,
    required String uid,
    int pageSize = NotificationRepository.defaultPageSize,
    HomeWidgetService? homeWidgetService,
  }) : _repository = repository,
       _uid = uid,
       _pageSize = pageSize,
       _homeWidget = homeWidgetService ?? HomeWidgetService();

  final NotificationRepository _repository;
  final String _uid;
  final int _pageSize;

  /// Mirrors the loaded notifications into the home-screen widget's shared
  /// container so its snapshot tracks the in-app list. Every list mutation here
  /// is the only signal the widget gets — the widget process can't reach
  /// Firestore — so the controller refreshes it after each change.
  final HomeWidgetService _homeWidget;

  List<AppNotification> _notifications = const <AppNotification>[];

  /// Every notification loaded so far, newest-first, accumulated across pages.
  /// Returned read-only so callers can't mutate the controller's state in place.
  List<AppNotification> get notifications =>
      List<AppNotification>.unmodifiable(_notifications);

  /// The last page's trailing document, used as the `startAfter` cursor for the
  /// next [loadMore]. `null` before the first load and after an empty result.
  DocumentSnapshot<Map<String, dynamic>>? _cursor;

  bool _hasMore = true;

  /// Whether another page exists after what's loaded. Starts optimistically
  /// `true` (the first load hasn't run yet) and is pinned to each page's
  /// [NotificationPage.hasMore] thereafter.
  bool get hasMore => _hasMore;

  bool _isInitialLoading = false;

  /// True while the first page is loading and nothing is on screen yet — the
  /// cue for a full-screen spinner.
  bool get isInitialLoading => _isInitialLoading;

  bool _isRefreshing = false;

  /// True while a pull-to-refresh reloads page one. The current list stays
  /// visible underneath, so this drives the refresh indicator, not the empty
  /// state.
  bool get isRefreshing => _isRefreshing;

  bool _isLoadingMore = false;

  /// True while a subsequent page is loading — the cue for a footer spinner.
  bool get isLoadingMore => _isLoadingMore;

  Object? _error;

  /// The most recent load failure, or `null` when the last load succeeded (or
  /// none has run). Cleared at the start of every load.
  Object? get error => _error;

  Object? _loadMoreError;

  /// The most recent [loadMore] failure, or `null`. Distinct from [error] so the
  /// inbox can show an inline retry affordance in the list footer — where the
  /// already-loaded list stays visible — without mistaking it for an
  /// initial-load failure (full-screen) or a refresh failure (SnackBar). Cleared
  /// at the start of every load and on a successful [loadMore].
  Object? get loadMoreError => _loadMoreError;

  /// Whether the list has loaded at least once and came back empty — the cue
  /// for the "no notifications yet" empty state (as opposed to the initial
  /// spinner, which shows while [isInitialLoading]).
  bool get isEmpty =>
      _notifications.isEmpty && !_isInitialLoading && _error == null;

  /// True while any load is in flight. Used to serialize loads: a new request
  /// that arrives while one is running is dropped rather than queued, so
  /// overlapping scroll/refresh gestures can't fire duplicate queries.
  bool get _isBusy => _isInitialLoading || _isRefreshing || _isLoadingMore;

  /// Loads the first page, replacing any existing state.
  ///
  /// Drives [isInitialLoading] (full-screen spinner) and is a no-op if any load
  /// is already running. Call once when the screen mounts; use [refresh] to
  /// reload afterwards.
  Future<void> loadInitial() async {
    if (_isBusy) return;
    _isInitialLoading = true;
    _error = null;
    _loadMoreError = null;
    notifyListeners();

    try {
      final page = await _repository.fetchPage(_uid, pageSize: _pageSize);
      _notifications = page.notifications;
      _cursor = page.cursor;
      _hasMore = page.hasMore;
      _syncWidget();
    } catch (e) {
      _error = e;
    } finally {
      _isInitialLoading = false;
      notifyListeners();
    }
  }

  /// Reloads page one, replacing the accumulated list, for pull-to-refresh.
  ///
  /// Unlike [loadInitial] this keeps the current list visible (driving
  /// [isRefreshing] rather than [isInitialLoading]) and only swaps it in once
  /// the new page arrives. On failure the existing list is left intact and
  /// [error] is set. A no-op if any load is already running.
  Future<void> refresh() async {
    if (_isBusy) return;
    _isRefreshing = true;
    _error = null;
    _loadMoreError = null;
    notifyListeners();

    try {
      final page = await _repository.fetchPage(_uid, pageSize: _pageSize);
      _notifications = page.notifications;
      _cursor = page.cursor;
      _hasMore = page.hasMore;
      _syncWidget();
    } catch (e) {
      _error = e;
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// Loads and appends the next page.
  ///
  /// Guarded on several fronts: it does nothing when another load is already
  /// running (the duplicate-request guard for repeated scroll callbacks), when
  /// [hasMore] is `false` (nothing left to fetch), or when there's no [_cursor]
  /// yet (the first page hasn't loaded — call [loadInitial] first). On success
  /// the page is appended and the cursor/[hasMore] advance; on failure the list
  /// is left intact, [error] is set, and the same [loadMore] can be retried.
  Future<void> loadMore() async {
    if (_isBusy || !_hasMore || _cursor == null) return;
    _isLoadingMore = true;
    _error = null;
    _loadMoreError = null;
    notifyListeners();

    try {
      final page = await _repository.fetchPage(
        _uid,
        pageSize: _pageSize,
        startAfter: _cursor,
      );
      _notifications = <AppNotification>[
        ..._notifications,
        ...page.notifications,
      ];
      // Advance the cursor only when the page carried one; an empty trailing
      // page leaves the previous cursor in place but pins hasMore false below.
      _cursor = page.cursor ?? _cursor;
      _hasMore = page.hasMore;
      // No widget sync here: loadMore only appends pages *older* than the
      // widget's newest-N snapshot, so the mirrored set never changes.
    } catch (e) {
      _error = e;
      _loadMoreError = e;
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  /// Re-reads a single loaded notification and swaps it into the list in place.
  ///
  /// Used after a row mutates its own Firestore document — the read flip when
  /// its detail screen opens, or a bookmark toggle. Re-reading just that one
  /// document (rather than [refresh]ing page one) is what keeps pagination from
  /// resetting: the accumulated pages, scroll position, [_cursor] and [hasMore]
  /// all stay put while the one changed row picks up its new state.
  ///
  /// The list is re-read *after* the fetch, not captured before it, so a
  /// [loadMore] that lands mid-flight (appending a page) isn't clobbered — the
  /// map runs over whatever the list holds when the document comes back. A
  /// missing document (deleted, or never loaded) is a no-op. Deliberately not
  /// guarded by [_isBusy]: it issues a single point read, not a page query, so
  /// there's nothing to serialize against the paginated loads.
  Future<void> reloadNotification(String id) async {
    final updated = await _repository.fetchById(_uid, id);
    if (updated == null) return;
    var changed = false;
    _notifications = _notifications.map((n) {
      if (n.id == id) {
        changed = true;
        return updated;
      }
      return n;
    }).toList();
    if (changed) {
      _syncWidget();
      notifyListeners();
    }
  }

  /// Flips every loaded notification to read, in place.
  ///
  /// Called after [NotificationRepository.markAllRead] has written the flag to
  /// Firestore. Like [reloadNotification] this avoids a [refresh]: mark-all-read
  /// shouldn't cost the user their loaded pages and scroll position. Any unread
  /// documents that haven't been loaded yet are already read in Firestore and
  /// will arrive read on a later [loadMore].
  void markAllReadLocally() {
    var changed = false;
    _notifications = _notifications.map((n) {
      if (n.read) return n;
      changed = true;
      return n.copyWith(read: true);
    }).toList();
    if (changed) {
      _syncWidget();
      notifyListeners();
    }
  }

  /// Pushes the current newest-first list into the home-screen widget's shared
  /// container and triggers a native redraw.
  ///
  /// Fire-and-forget: [HomeWidgetService.sync] is best-effort and swallows its
  /// own errors, so there is nothing to await or surface. Called after every
  /// mutation that changes the widget's newest-N snapshot — the initial load, a
  /// refresh, and the read/bookmark flips ([reloadNotification],
  /// [markAllReadLocally]). Deliberately *not* called from [loadMore], whose
  /// appended pages are older than that snapshot.
  void _syncWidget() {
    unawaited(_homeWidget.sync(_notifications));
  }
}
