// Widget test for [NotificationInboxScreen]'s empty state.
//
// Kept minimal: it fakes the repository to emit an empty notification list and
// asserts the "no notifications yet" empty state renders. It deliberately
// avoids seeding documents or driving search/mark-read, which would make the
// test brittle against UI tweaks.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/features/auth/auth_service.dart';
import 'package:notifyme/features/notifications/notification_inbox_screen.dart';
import 'package:notifyme/features/notifications/notification_model.dart';
import 'package:notifyme/features/notifications/notification_repository.dart';

/// Stand-in Firebase instances that are stored but never used: the fakes below
/// override every method the screen calls.
class _UnusedFirebaseAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FirebaseAuth should not be used in tests');
}

class _UnusedFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Firestore should not be used in tests');
}

/// A signed-in user — the screen only reads [User.uid] to scope its query.
class _FakeUser implements User {
  @override
  String get uid => 'test-uid';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Only User.uid is used in tests');
}

class _FakeAuthService extends AuthService {
  _FakeAuthService()
    : super(auth: _UnusedFirebaseAuth(), firestore: _UnusedFirestore());

  @override
  User? get currentUser => _FakeUser();
}

class _FakeNotificationRepository extends NotificationRepository {
  _FakeNotificationRepository(this._notifications)
    : super(firestore: _UnusedFirestore());

  final List<AppNotification> _notifications;

  @override
  Stream<List<AppNotification>> watchForUser(String uid, {int? limit = 100}) =>
      Stream<List<AppNotification>>.value(_notifications);
}

void main() {
  testWidgets('renders the empty state when there are no notifications', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationInboxScreen(
          authService: _FakeAuthService(),
          repository: _FakeNotificationRepository(const []),
        ),
      ),
    );
    await tester.pump(); // let the stream deliver the empty list

    expect(find.text('No notifications yet'), findsOneWidget);
    expect(
      find.text('POST to your webhook URL and it’ll show up here.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.notifications_none), findsOneWidget);
  });
}
