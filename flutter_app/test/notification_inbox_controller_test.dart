// Behavior tests for [NotificationInboxController] — the pagination state
// machine over [NotificationRepository.fetchPage].
//
// Real pagination (cursors, ordering, hasMore) runs against the in-memory fake
// Firestore via the real repository, so the tests exercise genuine cursor
// logic. A thin [_ScriptedRepository] subclass layers in a gate (to hold a
// fetch open and race two loads) and a one-shot failure (to drive the error
// path) without faking DocumentSnapshots.
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/features/notifications/notification_date_group.dart';
import 'package:notifyme/features/notifications/notification_inbox_controller.dart';
import 'package:notifyme/features/notifications/notification_repository.dart';
import 'package:notifyme/features/widget/home_widget_service.dart';

import 'support/fake_firestore.dart';

/// Records every [HomeWidgetService.sync]/`clear` call so a test can assert the
/// controller mirrors its list into the home-screen widget. Holds the most
/// recent synced item ids (newest-first) and a running call count.
class _RecordingHomeWidgetClient implements HomeWidgetClient {
  final Map<String, String?> data = <String, String?>{};
  int syncCount = 0;

  @override
  Future<void> setAppGroupId(String groupId) async {}

  @override
  Future<void> saveWidgetData(String key, String? value) async {
    data[key] = value;
    if (key == HomeWidgetService.itemsKey) syncCount++;
  }

  @override
  Future<void> updateWidget({String? iOSName, String? androidName}) async {}

  List<String> get syncedIds {
    final raw = data[HomeWidgetService.itemsKey];
    if (raw == null) return const <String>[];
    return (jsonDecode(raw) as List<dynamic>)
        .map((e) => (e as Map<String, dynamic>)['id'] as String)
        .toList();
  }
}

/// Wraps the real repository so a test can (a) pause a `fetchPage` on [gate]
/// until it completes the completer, and (b) make the next `fetchPage` throw
/// [failWith]. It also counts calls so the duplicate-request guard is testable.
class _ScriptedRepository extends NotificationRepository {
  _ScriptedRepository(FakeFirestore fs) : super(firestore: fs);

  /// When set, the next `fetchPage` awaits this before doing anything else.
  Completer<void>? gate;

  /// When set, the next `fetchPage` throws this (and clears it).
  Object? failWith;

  int fetchPageCalls = 0;

  @override
  Future<NotificationPage> fetchPage(
    String uid, {
    int pageSize = NotificationRepository.defaultPageSize,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    fetchPageCalls++;
    final g = gate;
    if (g != null) await g.future;
    final f = failWith;
    if (f != null) {
      failWith = null;
      throw f;
    }
    return super.fetchPage(uid, pageSize: pageSize, startAfter: startAfter);
  }
}

void main() {
  late FakeFirestore fs;
  late _ScriptedRepository repo;
  late _RecordingHomeWidgetClient widget;
  late StreamController<RemoteMessage> foreground;

  setUp(() {
    fs = FakeFirestore();
    repo = _ScriptedRepository(fs);
    widget = _RecordingHomeWidgetClient();
    foreground = StreamController<RemoteMessage>.broadcast();
  });

  tearDown(() => foreground.close());

  // Lets the fire-and-forget _syncWidget() future settle before assertions.
  Future<void> flushWidgetSync() => Future<void>.delayed(Duration.zero);

  // Seeds n0..n[count-1] with ascending createdAt, so the newest-first order
  // is n[count-1], …, n1, n0.
  void seedRun(int count, {String uid = 'me'}) {
    for (var i = 0; i < count; i++) {
      fs.seed('notifications/n$i', {
        'uid': uid,
        'title': 't',
        'message': 'm',
        'read': false,
        'bookmarked': false,
        'createdAt': Timestamp.fromDate(DateTime(2026, 5, 1, 0, i)),
      });
    }
  }

  NotificationInboxController controller({int pageSize = 2, String uid = 'me'}) =>
      NotificationInboxController(
        repository: repo,
        uid: uid,
        pageSize: pageSize,
        homeWidgetService: HomeWidgetService(client: widget),
        foregroundMessages: foreground.stream,
      );

  group('loadInitial', () {
    test('loads the first page newest-first and tracks cursor/hasMore', () async {
      seedRun(5);
      final c = controller(pageSize: 2);

      await c.loadInitial();

      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3']);
      expect(c.hasMore, isTrue);
      expect(c.isInitialLoading, isFalse);
      expect(c.error, isNull);
    });

    test('toggles isInitialLoading and notifies during the load', () async {
      seedRun(3);
      final c = controller(pageSize: 2);
      final loadingDuringLoad = <bool>[];
      c.addListener(() => loadingDuringLoad.add(c.isInitialLoading));

      await c.loadInitial();

      // First notification fires with loading true, last with it false.
      expect(loadingDuringLoad.first, isTrue);
      expect(loadingDuringLoad.last, isFalse);
    });

    test('an empty result flags isEmpty and stops pagination', () async {
      final c = controller(pageSize: 2);

      await c.loadInitial();

      expect(c.notifications, isEmpty);
      expect(c.hasMore, isFalse);
      expect(c.isEmpty, isTrue);
    });

    test('captures a load error and is not empty', () async {
      repo.failWith = StateError('boom');
      final c = controller(pageSize: 2);

      await c.loadInitial();

      expect(c.error, isA<StateError>());
      expect(c.notifications, isEmpty);
      expect(c.isInitialLoading, isFalse);
      expect(c.isEmpty, isFalse); // an error is not the empty state
    });
  });

  group('loadMore', () {
    test('appends the next page and advances the cursor', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();

      await c.loadMore();

      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3', 'n2', 'n1']);
      expect(c.hasMore, isTrue);
    });

    test('the final page sets hasMore false', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();
      await c.loadMore(); // n2, n1

      await c.loadMore(); // n0

      expect(c.notifications.map((n) => n.id).toList(), [
        'n4',
        'n3',
        'n2',
        'n1',
        'n0',
      ]);
      expect(c.hasMore, isFalse);
    });

    test('is a no-op before the first page is loaded', () async {
      seedRun(5);
      final c = controller(pageSize: 2);

      await c.loadMore();

      expect(c.notifications, isEmpty);
      expect(repo.fetchPageCalls, 0);
    });

    test('is dropped while the initial load is still in flight', () async {
      seedRun(6);
      final c = controller(pageSize: 2);

      // Hold the initial fetch open, then fire loadMore before it resolves.
      final gate = Completer<void>();
      repo.gate = gate;
      final initial = c.loadInitial();
      expect(c.isInitialLoading, isTrue);

      await c.loadMore(); // dropped: a load is already running
      expect(repo.fetchPageCalls, 1); // only the initial fetch

      gate.complete();
      repo.gate = null;
      await initial;
      expect(c.notifications.map((n) => n.id).toList(), ['n5', 'n4']);
    });

    test('an empty trailing page keeps the list and stops pagination', () async {
      // Page one reports hasMore true, but the rest of the run is deleted
      // before loadMore runs (a concurrent purge). The follow-up fetch comes
      // back empty: the loaded rows must survive and pagination must stop.
      seedRun(4);
      final c = controller(pageSize: 2);
      await c.loadInitial(); // n3, n2 — hasMore true
      expect(c.hasMore, isTrue);

      fs.store.remove('notifications/n1');
      fs.store.remove('notifications/n0');

      await c.loadMore();

      expect(c.notifications.map((n) => n.id).toList(), ['n3', 'n2']);
      expect(c.hasMore, isFalse);
      expect(c.isLoadingMore, isFalse);
      expect(c.error, isNull);
    });

    test('is a no-op once hasMore is false', () async {
      seedRun(2); // exactly one page, hasMore false
      final c = controller(pageSize: 2);
      await c.loadInitial();
      expect(c.hasMore, isFalse);
      final callsAfterInitial = repo.fetchPageCalls;

      await c.loadMore();

      expect(repo.fetchPageCalls, callsAfterInitial);
    });

    test('a failed loadMore keeps the loaded list and can be retried', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();

      repo.failWith = StateError('transient');
      await c.loadMore();

      expect(c.error, isA<StateError>());
      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3']);
      expect(c.isLoadingMore, isFalse);

      // Retry succeeds and clears the error.
      await c.loadMore();
      expect(c.error, isNull);
      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3', 'n2', 'n1']);
    });

    test('a failed loadMore sets loadMoreError, cleared on a successful retry', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();

      repo.failWith = StateError('transient');
      await c.loadMore();
      expect(c.loadMoreError, isA<StateError>());

      await c.loadMore();
      expect(c.loadMoreError, isNull);
    });

    test('a refresh clears a lingering loadMoreError', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();

      repo.failWith = StateError('transient');
      await c.loadMore();
      expect(c.loadMoreError, isA<StateError>());

      await c.refresh();
      expect(c.loadMoreError, isNull);
    });

    test('overlapping loadMore calls issue only one query', () async {
      seedRun(6);
      final c = controller(pageSize: 2);
      await c.loadInitial();

      // Hold the next fetch open so both loadMore calls overlap.
      final gate = Completer<void>();
      repo.gate = gate;
      final callsBefore = repo.fetchPageCalls;

      final first = c.loadMore();
      final second = c.loadMore(); // should be dropped by the busy guard
      expect(c.isLoadingMore, isTrue);

      gate.complete();
      repo.gate = null;
      await Future.wait([first, second]);

      expect(repo.fetchPageCalls, callsBefore + 1);
      expect(c.notifications.map((n) => n.id).toList(), ['n5', 'n4', 'n3', 'n2']);
    });
  });

  group('refresh', () {
    test('reloads page one and keeps the list visible while refreshing', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();
      await c.loadMore(); // now 4 loaded

      // Snapshot whether the list was non-empty at the moment refreshing began.
      final listNonEmptyWhileRefreshing = <bool>[];
      c.addListener(() {
        if (c.isRefreshing) {
          listNonEmptyWhileRefreshing.add(c.notifications.isNotEmpty);
        }
      });

      await c.refresh();

      expect(listNonEmptyWhileRefreshing, contains(true));
      // Back to just page one, newest-first.
      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3']);
      expect(c.hasMore, isTrue);
      expect(c.isRefreshing, isFalse);
    });

    test('resets the cursor so the next loadMore re-fetches from page two', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial(); // n4, n3
      await c.loadMore(); // n2, n1
      await c.loadMore(); // n0 — hasMore now false
      expect(c.hasMore, isFalse);

      await c.refresh(); // back to page one
      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3']);
      expect(c.hasMore, isTrue); // pagination re-enabled

      // The cursor was reset to page one's, so loadMore fetches page *two*
      // again — not the page after the pre-refresh tail.
      await c.loadMore();
      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3', 'n2', 'n1']);
    });

    test('a failed refresh leaves the existing list intact', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();

      repo.failWith = StateError('offline');
      await c.refresh();

      expect(c.error, isA<StateError>());
      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3']);
    });

    test('loadMore is dropped while a refresh is in flight', () async {
      seedRun(6);
      final c = controller(pageSize: 2);
      await c.loadInitial();

      final gate = Completer<void>();
      repo.gate = gate;
      final callsBefore = repo.fetchPageCalls;

      final refreshing = c.refresh();
      await c.loadMore(); // dropped: a load is already running
      expect(c.isRefreshing, isTrue);

      gate.complete();
      repo.gate = null;
      await refreshing;

      expect(repo.fetchPageCalls, callsBefore + 1);
    });
  });

  group('reloadNotification', () {
    test('reconciles one loaded row in place without resetting pagination', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();
      await c.loadMore(); // n4, n3, n2, n1 across two pages
      final pagesLoaded = repo.fetchPageCalls;

      // Flip n3 read directly in Firestore (as the detail screen would), then
      // reconcile just that row.
      await repo.markRead('me', 'n3');
      await c.reloadNotification('n3');

      // The accumulated four-row list survives — pagination did not collapse to
      // page one — and no extra page query was issued.
      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3', 'n2', 'n1']);
      expect(c.hasMore, isTrue);
      expect(repo.fetchPageCalls, pagesLoaded);
      // ...and the reconciled row reflects its new read state.
      expect(c.notifications.firstWhere((n) => n.id == 'n3').read, isTrue);
      expect(c.notifications.firstWhere((n) => n.id == 'n4').read, isFalse);
    });

    test('is a no-op when the id is not loaded', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial(); // n4, n3 only
      var notified = 0;
      c.addListener(() => notified++);

      await c.reloadNotification('n0'); // exists in Firestore but not loaded

      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3']);
      expect(notified, 0);
    });
  });

  group('markAllReadLocally', () {
    test('flips every loaded row read without resetting pagination', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();
      await c.loadMore(); // four rows loaded
      final pagesLoaded = repo.fetchPageCalls;

      c.markAllReadLocally();

      expect(c.notifications.map((n) => n.id).toList(), ['n4', 'n3', 'n2', 'n1']);
      expect(c.notifications.every((n) => n.read), isTrue);
      expect(c.hasMore, isTrue);
      expect(repo.fetchPageCalls, pagesLoaded); // no refetch
    });
  });

  group('home-screen widget sync', () {
    test('loadInitial mirrors the newest-first list into the widget', () async {
      seedRun(5);
      final c = controller(pageSize: 2);

      await c.loadInitial();
      await flushWidgetSync();

      expect(widget.syncedIds, ['n4', 'n3']);
      expect(widget.data[HomeWidgetService.unreadKey], '2');
    });

    test('refresh re-mirrors page one into the widget', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();
      await flushWidgetSync();

      await c.refresh();
      await flushWidgetSync();

      expect(widget.syncedIds, ['n4', 'n3']);
    });

    test('loadMore does not re-sync the widget (older pages only)', () async {
      seedRun(5);
      final c = controller(pageSize: 2);
      await c.loadInitial();
      await flushWidgetSync();
      final countAfterInitial = widget.syncCount;

      await c.loadMore();
      await flushWidgetSync();

      // The appended page is older than the widget's newest-N snapshot.
      expect(widget.syncCount, countAfterInitial);
      expect(widget.syncedIds, ['n4', 'n3']);
    });

    test('markAllReadLocally re-mirrors with the flipped read state', () async {
      seedRun(3);
      final c = controller(pageSize: 4); // one page, all loaded
      await c.loadInitial();
      await flushWidgetSync();
      expect(widget.data[HomeWidgetService.unreadKey], '3');

      c.markAllReadLocally();
      await flushWidgetSync();

      expect(widget.data[HomeWidgetService.unreadKey], '0');
    });

    test('reloadNotification re-mirrors a reconciled row', () async {
      seedRun(3);
      final c = controller(pageSize: 4);
      await c.loadInitial();
      await flushWidgetSync();
      final countBefore = widget.syncCount;

      await repo.markRead('me', 'n2');
      await c.reloadNotification('n2');
      await flushWidgetSync();

      expect(widget.syncCount, greaterThan(countBefore));
      expect(widget.data[HomeWidgetService.unreadKey], '2');
    });
  });

  group('foreground push', () {
    // Emits a foreground RemoteMessage and lets the controller's async handler
    // (a point read plus an in-place splice) settle before assertions.
    Future<void> deliver(Map<String, String> data) async {
      foreground.add(RemoteMessage(data: data));
      await pumpEventQueue();
    }

    test('prepends a just-arrived notification to the list', () async {
      seedRun(3); // n0, n1, n2 — newest-first n2, n1, n0
      final c = controller(pageSize: 2);
      await c.loadInitial(); // n2, n1
      expect(c.notifications.map((n) => n.id).toList(), ['n2', 'n1']);

      // A new notification lands in Firestore, then its push arrives.
      fs.seed('notifications/n3', {
        'uid': 'me',
        'title': 't',
        'message': 'm',
        'read': false,
        'bookmarked': false,
        'createdAt': Timestamp.fromDate(DateTime(2026, 5, 1, 1)),
      });
      await deliver({'notificationId': 'n3'});

      expect(c.notifications.first.id, 'n3');
      expect(c.notifications.map((n) => n.id).toList(), ['n3', 'n2', 'n1']);
    });

    test('re-mirrors the widget snapshot with the new item', () async {
      seedRun(2);
      final c = controller(pageSize: 2);
      await c.loadInitial();
      await flushWidgetSync();

      fs.seed('notifications/n2', {
        'uid': 'me',
        'title': 't',
        'message': 'm',
        'read': false,
        'bookmarked': false,
        'createdAt': Timestamp.fromDate(DateTime(2026, 5, 1, 1)),
      });
      await deliver({'notificationId': 'n2'});
      await flushWidgetSync();

      expect(widget.syncedIds.first, 'n2');
      expect(widget.data[HomeWidgetService.unreadKey], '3');
    });

    test('replaces an already-loaded copy rather than duplicating it', () async {
      seedRun(3);
      final c = controller(pageSize: 4); // all loaded: n2, n1, n0
      await c.loadInitial();

      // A push for a notification already in the list (e.g. arriving after a
      // refresh already pulled it in) must not duplicate the row.
      await deliver({'notificationId': 'n1'});

      expect(c.notifications.map((n) => n.id).toList(), ['n1', 'n2', 'n0']);
    });

    test('ignores a push with no notificationId', () async {
      seedRun(2);
      final c = controller(pageSize: 2);
      await c.loadInitial();
      var notified = 0;
      c.addListener(() => notified++);

      await deliver({'url': 'https://example.com'});

      expect(c.notifications.map((n) => n.id).toList(), ['n1', 'n0']);
      expect(notified, 0);
    });

    test('ignores a push whose document belongs to another user', () async {
      seedRun(2);
      fs.seed('notifications/other', {
        'uid': 'someone-else',
        'title': 't',
        'message': 'm',
        'read': false,
        'bookmarked': false,
        'createdAt': Timestamp.fromDate(DateTime(2026, 5, 1, 1)),
      });
      final c = controller(pageSize: 2);
      await c.loadInitial();

      await deliver({'notificationId': 'other'});

      expect(c.notifications.map((n) => n.id).toList(), ['n1', 'n0']);
    });

    test('stops folding pushes after dispose', () async {
      seedRun(2);
      final c = controller(pageSize: 2);
      await c.loadInitial();
      c.dispose();

      fs.seed('notifications/n2', {
        'uid': 'me',
        'title': 't',
        'message': 'm',
        'read': false,
        'bookmarked': false,
        'createdAt': Timestamp.fromDate(DateTime(2026, 5, 1, 1)),
      });
      // Adding after dispose must not throw (no notifyListeners on a disposed
      // ChangeNotifier) — the subscription was cancelled.
      foreground.add(RemoteMessage(data: {'notificationId': 'n2'}));
      await pumpEventQueue();

      expect(c.notifications.map((n) => n.id).toList(), ['n1', 'n0']);
    });
  });

  group('day grouping across page boundaries', () {
    // Two notifications share May 1 and two share May 2; the page boundary
    // (pageSize 2) falls *inside* the May 2 run. Because the controller
    // accumulates pages into one flat list, grouping the result must yield a
    // single header per day — not a duplicate header where the pages joined.
    test('a day that straddles a page boundary groups under one header', () async {
      fs.seed('notifications/a', _doc(DateTime(2026, 5, 2, 9, 0)));
      fs.seed('notifications/b', _doc(DateTime(2026, 5, 2, 8, 0)));
      fs.seed('notifications/c', _doc(DateTime(2026, 5, 1, 9, 0)));
      fs.seed('notifications/d', _doc(DateTime(2026, 5, 1, 8, 0)));

      final c = controller(pageSize: 2);
      await c.loadInitial(); // a, b  (the May 2 run, ending page one)
      await c.loadMore(); // c, d  (May 1)

      final groups = NotificationDateGroup.groupByDay(
        c.notifications,
        now: DateTime(2026, 6, 2),
      );

      expect(groups.map((g) => g.label).toList(), ['May 2', 'May 1']);
      expect(groups[0].notifications.map((n) => n.id).toList(), ['a', 'b']);
      expect(groups[1].notifications.map((n) => n.id).toList(), ['c', 'd']);
    });
  });
}

Map<String, dynamic> _doc(DateTime createdAt) => {
  'uid': 'me',
  'title': 't',
  'message': 'm',
  'read': false,
  'bookmarked': false,
  'createdAt': Timestamp.fromDate(createdAt),
};
