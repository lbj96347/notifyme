// Tests for [NotificationTapRouter]'s home-screen-widget deep-link routing.
//
// The router consumes `notifyme://…` URLs from `home_widget` (a `widgetClicked`
// stream while running, `initiallyLaunchedFromHomeWidget()` for a cold start)
// and turns them into navigation. Both sources are replaced by a fake
// [WidgetLaunchClient] so no platform channel is touched, and the FCM tap
// streams are injected as empty so `register` never reaches FirebaseMessaging's
// static getters. `fetchById` runs against the in-memory [FakeFirestore]; the
// detail presentation is captured through the injected `showDetail` seam so the
// real detail screen (which reads Firebase in initState) is never built.
import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/app/home_tab.dart';
import 'package:notifyme/features/notifications/notification_model.dart';
import 'package:notifyme/features/notifications/notification_repository.dart';
import 'package:notifyme/features/notifications/notification_tap_router.dart';

import 'support/fake_firestore.dart';

class _FakeMessaging implements FirebaseMessaging {
  @override
  Future<RemoteMessage?> getInitialMessage() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeMessaging.${invocation.memberName}');
}

class _FakeWidgetLaunch implements WidgetLaunchClient {
  _FakeWidgetLaunch({this.initialUri});

  /// URL that "cold-started" the app from a terminated state (null = none).
  Uri? initialUri;

  final StreamController<Uri?> _clicks = StreamController<Uri?>.broadcast();

  /// Simulates a widget tap while the app is running.
  void emit(Uri? uri) => _clicks.add(uri);

  Future<void> close() => _clicks.close();

  @override
  Stream<Uri?> get widgetClicked => _clicks.stream;

  @override
  Future<Uri?> initiallyLaunchedFromHomeWidget() async => initialUri;
}

void main() {
  const uid = 'u1';

  late FakeFirestore firestore;
  late NotificationRepository repository;
  late _FakeWidgetLaunch widgetLaunch;
  late GlobalKey<NavigatorState> navKey;
  late List<AppNotification> presented;

  setUp(() {
    firestore = FakeFirestore();
    repository = NotificationRepository(firestore: firestore);
    widgetLaunch = _FakeWidgetLaunch();
    navKey = GlobalKey<NavigatorState>();
    presented = <AppNotification>[];
    homeTabIndex.value = homeInboxTabIndex;
  });

  tearDown(() async {
    await widgetLaunch.close();
  });

  void seedNotification(String id) {
    firestore.seed('notifications/$id', <String, dynamic>{
      'uid': uid,
      'title': 'Build $id',
      'message': 'done',
      'category': 'ci',
      'status': 'success',
      'read': false,
    });
  }

  NotificationTapRouter buildRouter() {
    return NotificationTapRouter(
      uid: uid,
      messaging: _FakeMessaging(),
      repository: repository,
      navigatorKey: navKey,
      widgetLaunch: widgetLaunch,
      openedAppStream: const Stream<RemoteMessage>.empty(),
      foregroundStream: const Stream<RemoteMessage>.empty(),
      showDetail: (n) async => presented.add(n),
    );
  }

  // A minimal host so the router has a real navigator to drive. The first route
  // stands in for HomePage; tests can push a second route to assert pop-to-root.
  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Text('home')),
      ),
    );
  }

  testWidgets('notification deep link opens the matching notification', (
    tester,
  ) async {
    seedNotification('n1');
    await pumpHost(tester);
    final router = buildRouter();
    await router.register();

    widgetLaunch.emit(Uri.parse('notifyme://notification/n1'));
    await tester.pumpAndSettle();

    expect(presented, hasLength(1));
    expect(presented.single.id, 'n1');

    await router.dispose();
  });

  testWidgets('notification deep link for a missing id falls back to inbox', (
    tester,
  ) async {
    await pumpHost(tester);
    homeTabIndex.value = 2; // pretend Settings is showing
    final router = buildRouter();
    await router.register();

    widgetLaunch.emit(Uri.parse('notifyme://notification/ghost'));
    await tester.pumpAndSettle();

    expect(presented, isEmpty);
    expect(homeTabIndex.value, homeInboxTabIndex);

    await router.dispose();
  });

  testWidgets('notification deep link with an empty id falls back to inbox', (
    tester,
  ) async {
    await pumpHost(tester);
    homeTabIndex.value = 2;
    final router = buildRouter();
    await router.register();

    // `notifyme://notification/` and `notifyme://notification` both yield no
    // usable id. The native widget shouldn't emit these (its `canDeepLink`
    // guard routes idless rows to the inbox), but the router defends anyway.
    widgetLaunch.emit(Uri.parse('notifyme://notification/'));
    widgetLaunch.emit(Uri.parse('notifyme://notification'));
    await tester.pumpAndSettle();

    expect(presented, isEmpty);
    expect(homeTabIndex.value, homeInboxTabIndex);

    await router.dispose();
  });

  testWidgets('a null widget click is ignored', (tester) async {
    await pumpHost(tester);
    homeTabIndex.value = 2;
    final router = buildRouter();
    await router.register();

    widgetLaunch.emit(null);
    await tester.pumpAndSettle();

    expect(presented, isEmpty);
    expect(homeTabIndex.value, 2); // untouched

    await router.dispose();
  });

  testWidgets('inbox deep link selects the inbox tab and pops to root', (
    tester,
  ) async {
    await pumpHost(tester);
    homeTabIndex.value = 2;
    // Push a detail-like route on top of the inbox root.
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('detail')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);

    final router = buildRouter();
    await router.register();

    widgetLaunch.emit(Uri.parse('notifyme://inbox'));
    await tester.pumpAndSettle();

    expect(homeTabIndex.value, homeInboxTabIndex);
    expect(find.text('detail'), findsNothing); // popped back to root
    expect(find.text('home'), findsOneWidget);

    await router.dispose();
  });

  testWidgets('a widget tap that cold-started the app routes after first frame', (
    tester,
  ) async {
    seedNotification('n7');
    widgetLaunch.initialUri = Uri.parse('notifyme://notification/n7');
    await pumpHost(tester);

    final router = buildRouter();
    await router.register();
    // The cold-start link is deferred to a post-frame callback.
    await tester.pumpAndSettle();

    expect(presented.single.id, 'n7');

    await router.dispose();
  });

  testWidgets('unknown hosts and foreign schemes are ignored', (tester) async {
    await pumpHost(tester);
    homeTabIndex.value = 2;
    final router = buildRouter();
    await router.register();

    widgetLaunch.emit(Uri.parse('notifyme://settings'));
    widgetLaunch.emit(Uri.parse('https://example.com/x'));
    await tester.pumpAndSettle();

    expect(presented, isEmpty);
    expect(homeTabIndex.value, 2); // untouched

    await router.dispose();
  });

  testWidgets('dispose stops routing further widget clicks', (tester) async {
    seedNotification('n1');
    await pumpHost(tester);
    final router = buildRouter();
    await router.register();
    await router.dispose();

    widgetLaunch.emit(Uri.parse('notifyme://notification/n1'));
    await tester.pumpAndSettle();

    expect(presented, isEmpty);
  });
}
