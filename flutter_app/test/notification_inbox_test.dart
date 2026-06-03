// Widget tests for [NotificationInboxScreen].
//
// The screen drives a [NotificationInboxController] over the real repository
// against an in-memory [FakeFirestore], so pagination/cursor logic is genuine.
// A thin [_ScriptedRepository] adds a one-shot failure so the refresh error
// path can be exercised. Auth is faked to a fixed uid; the screen only reads
// [User.uid].
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/features/auth/auth_service.dart';
import 'package:notifyme/features/notifications/notification_inbox_screen.dart';
import 'package:notifyme/features/notifications/notification_repository.dart';

import 'support/fake_firestore.dart';

/// Stand-in Firebase Auth that is stored but never used: the fake below
/// overrides the only method the screen calls.
class _UnusedFirebaseAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FirebaseAuth should not be used in tests');
}

/// A signed-in user — the screen only reads [User.uid] to scope its query.
class _FakeUser implements User {
  @override
  String get uid => 'me';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Only User.uid is used in tests');
}

class _FakeAuthService extends AuthService {
  _FakeAuthService(FakeFirestore fs)
    : super(auth: _UnusedFirebaseAuth(), firestore: fs);

  @override
  User? get currentUser => _FakeUser();
}

/// Wraps the real repository so the next `fetchPage` can be made to throw,
/// driving the refresh error path.
class _ScriptedRepository extends NotificationRepository {
  _ScriptedRepository(FakeFirestore fs) : super(firestore: fs);

  Object? failWith;

  @override
  Future<NotificationPage> fetchPage(
    String uid, {
    int pageSize = NotificationRepository.defaultPageSize,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
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

  setUp(() {
    fs = FakeFirestore();
    repo = _ScriptedRepository(fs);
  });

  void seed(String id, {String uid = 'me', int minute = 0}) {
    fs.seed('notifications/$id', {
      'uid': uid,
      'title': 'Title $id',
      'message': 'Message $id',
      'read': false,
      'bookmarked': false,
      'createdAt': Timestamp.fromDate(DateTime(2026, 5, 1, 0, minute)),
    });
  }

  Future<void> pumpInbox(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationInboxScreen(
          authService: _FakeAuthService(fs),
          repository: repo,
        ),
      ),
    );
    // Let loadInitial() complete and the list render.
    await tester.pumpAndSettle();
  }

  testWidgets('renders the empty state when there are no notifications', (
    tester,
  ) async {
    await pumpInbox(tester);

    expect(find.text('No notifications yet'), findsOneWidget);
    expect(
      find.text('POST to your webhook URL and it’ll show up here.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.notifications_none), findsOneWidget);
  });

  testWidgets('renders the loaded notifications', (tester) async {
    seed('n0', minute: 0);
    seed('n1', minute: 1);
    await pumpInbox(tester);

    expect(find.text('Title n1'), findsOneWidget);
    expect(find.text('Title n0'), findsOneWidget);
  });

  testWidgets('shows the end-of-list footer when a single page is loaded', (
    tester,
  ) async {
    // One notification is well under a page, so hasMore is false after the
    // initial load and the "all caught up" marker should appear.
    seed('n0', minute: 0);
    await pumpInbox(tester);

    expect(find.text('Title n0'), findsOneWidget);
    expect(find.text('You’re all caught up'), findsOneWidget);
  });

  testWidgets('pull-to-refresh reloads the first page', (tester) async {
    seed('n0', minute: 0);
    await pumpInbox(tester);
    expect(find.text('Title n0'), findsOneWidget);

    // A new notification arrives in Firestore after the initial load.
    seed('n1', minute: 5);
    expect(find.text('Title n1'), findsNothing);

    // Pull down to refresh.
    await tester.fling(find.text('Title n0'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(find.text('Title n1'), findsOneWidget);
  });

  testWidgets('a failed refresh keeps the list and shows a SnackBar', (
    tester,
  ) async {
    seed('n0', minute: 0);
    await pumpInbox(tester);
    expect(find.text('Title n0'), findsOneWidget);

    repo.failWith = StateError('offline');
    await tester.fling(find.text('Title n0'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    // The existing list survives the failed refresh...
    expect(find.text('Title n0'), findsOneWidget);
    // ...and the failure is surfaced rather than silently swallowed.
    expect(find.text('Couldn’t refresh notifications.'), findsOneWidget);
  });

  testWidgets('a search with no match in a fully-loaded list says "No matches"', (
    tester,
  ) async {
    // A single page (well under the page size), so hasMore is false: search has
    // seen everything and can declare the absence definitive.
    seed('n0', minute: 0);
    await pumpInbox(tester);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'nonexistent');
    await tester.pumpAndSettle();

    expect(find.text('No matches'), findsOneWidget);
    // Nothing left to load, so no "load more" escape hatch is offered.
    expect(find.text('Load more results'), findsNothing);
  });

  testWidgets('a search miss with more pages offers to load more, then finds it', (
    tester,
  ) async {
    // 31 notifications => two pages at the default page size of 30. Only the
    // oldest (n0, last page) carries the term being searched.
    for (var i = 0; i < 31; i++) {
      fs.seed('notifications/n$i', {
        'uid': 'me',
        'title': i == 0 ? 'Needle' : 'Title n$i',
        'message': 'Message n$i',
        'read': false,
        'bookmarked': false,
        'createdAt': Timestamp.fromDate(DateTime(2026, 5, 1, 0, i)),
      });
    }
    await pumpInbox(tester);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'needle');
    await tester.pumpAndSettle();

    // The match is on the unloaded second page, so search can't claim "No
    // matches" — it offers to load more instead.
    expect(find.text('No matches yet'), findsOneWidget);
    expect(find.text('Load more results'), findsOneWidget);
    expect(find.text('Needle'), findsNothing);

    await tester.tap(find.text('Load more results'));
    await tester.pumpAndSettle();

    // The second page is in, and the filter now surfaces the match.
    expect(find.text('Needle'), findsOneWidget);
    expect(find.text('No matches yet'), findsNothing);
  });
}
