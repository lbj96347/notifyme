// Routes notification taps to the right destination across all app states.
//
// The webhook Cloud Function (firebase_functions/src/messaging.ts) attaches a
// `data` payload to every push — `notificationId`, `category`, `status`, `url`.
// When the user taps a notification we want to land them on the matching
// detail screen via `notificationId`, falling back to opening the `url` when
// that's all the payload carries.
//
// Firebase Messaging surfaces taps through three distinct entry points, one per
// app state, and this router wires up all three:
//
//   * terminated — `getInitialMessage()` returns the push that launched the app
//   * background — `onMessageOpenedApp` fires when a tray push is tapped
//   * foreground — `onMessage` delivers data while the app is open; the OS won't
//     show a tray notification in this state, so we surface a tappable banner
//
// Taps arrive outside the widget tree (from FCM streams), so navigation goes
// through [notificationNavigatorKey], which is installed on the root
// MaterialApp.

import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/home_tab.dart';
import '../widget/home_widget_service.dart';
import 'notification_detail_screen.dart';
import 'notification_model.dart';
import 'notification_repository.dart';

/// URL scheme for NotifyMe deep links emitted by the home-screen widget:
/// `notifyme://inbox` (open the inbox) and `notifyme://notification/{id}` (open
/// one notification). Registered with the OS in `ios/Runner/Info.plist` and
/// `android/.../AndroidManifest.xml`.
const String _deepLinkScheme = 'notifyme';
const String _deepLinkInboxHost = 'inbox';
const String _deepLinkNotificationHost = 'notification';

/// Seam over `home_widget`'s launch/click APIs so deep-link routing can be unit
/// tested without the platform channel.
///
/// The native widget deep-links each item to `notifyme://notification/{id}` and
/// its header/empty state to `notifyme://inbox`; `home_widget` surfaces those
/// URLs here — [widgetClicked] emits while the app is already running, and
/// [initiallyLaunchedFromHomeWidget] returns the URL that cold-started the app
/// from a terminated state.
abstract class WidgetLaunchClient {
  /// Binds `home_widget` reads to the shared App Group container on platforms
  /// that require it.
  Future<void> setAppGroupId(String groupId);

  Stream<Uri?> get widgetClicked;
  Future<Uri?> initiallyLaunchedFromHomeWidget();
}

/// Production [WidgetLaunchClient] backed by the real `home_widget` package.
class _DefaultWidgetLaunchClient implements WidgetLaunchClient {
  const _DefaultWidgetLaunchClient();

  @override
  Future<void> setAppGroupId(String groupId) =>
      HomeWidget.setAppGroupId(groupId);

  @override
  Stream<Uri?> get widgetClicked => HomeWidget.widgetClicked;

  @override
  Future<Uri?> initiallyLaunchedFromHomeWidget() =>
      HomeWidget.initiallyLaunchedFromHomeWidget();
}

/// Navigator key for the root MaterialApp, used to navigate from tap handlers
/// that run without a BuildContext. Installed in `main.dart`.
final GlobalKey<NavigatorState> notificationNavigatorKey =
    GlobalKey<NavigatorState>();

/// Wires Firebase Messaging taps **and** home-screen-widget deep links to
/// in-app navigation.
///
/// Construct once the user is signed in (so reads are scoped to a known [uid]
/// and the navigator exists) and call [register]. Call [dispose] on sign-out to
/// drop the stream subscriptions.
///
/// Two entry classes are handled, each across every app state:
///   * FCM taps — terminated (`getInitialMessage`), background
///     (`onMessageOpenedApp`), foreground (`onMessage` → banner).
///   * Widget deep links (`notifyme://…`) — terminated
///     (`initiallyLaunchedFromHomeWidget`) and running (`widgetClicked`).
class NotificationTapRouter {
  NotificationTapRouter({
    required this.uid,
    FirebaseMessaging? messaging,
    NotificationRepository? repository,
    GlobalKey<NavigatorState>? navigatorKey,
    WidgetLaunchClient? widgetLaunch,
    Stream<RemoteMessage>? openedAppStream,
    Stream<RemoteMessage>? foregroundStream,
    Future<void> Function(AppNotification notification)? showDetail,
  }) : _messaging = messaging ?? FirebaseMessaging.instance,
       _repository = repository ?? NotificationRepository(),
       _navigatorKey = navigatorKey ?? notificationNavigatorKey,
       _widgetLaunch = widgetLaunch ?? const _DefaultWidgetLaunchClient(),
       _openedAppStream = openedAppStream,
       _foregroundStream = foregroundStream,
       _showDetail = showDetail;

  final String uid;
  final FirebaseMessaging _messaging;
  final NotificationRepository _repository;
  final GlobalKey<NavigatorState> _navigatorKey;
  final WidgetLaunchClient _widgetLaunch;

  // FCM tap streams are static getters on FirebaseMessaging in production;
  // tests inject fakes so `register` never touches the platform channel.
  final Stream<RemoteMessage>? _openedAppStream;
  final Stream<RemoteMessage>? _foregroundStream;

  // How a resolved notification is presented; tests inject a recorder so the
  // detail screen (which reads Firebase in initState) isn't built. Production
  // leaves it null and uses [_pushDetail].
  final Future<void> Function(AppNotification notification)? _showDetail;

  StreamSubscription<RemoteMessage>? _openedSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<Uri?>? _widgetSub;

  /// Sets up tap handling for all app states. Safe to call once per sign-in;
  /// repeated calls replace any prior subscriptions.
  Future<void> register() async {
    await dispose();

    _openedSub = (_openedAppStream ?? FirebaseMessaging.onMessageOpenedApp)
        .listen(_openFromMessage);
    _foregroundSub = (_foregroundStream ?? FirebaseMessaging.onMessage).listen(
      _showForegroundBanner,
    );

    // A tap that cold-started the app from a terminated state. Deferred to the
    // next frame so the first route (HomePage) is mounted before we push onto
    // the navigator. Handled for both an FCM push and a widget deep link.
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openFromMessage(initialMessage);
      });
    }

    try {
      await _widgetLaunch.setAppGroupId(HomeWidgetService.defaultAppGroupId);
      _widgetSub = _widgetLaunch.widgetClicked.listen(_openFromUri);

      final launchUri = await _widgetLaunch.initiallyLaunchedFromHomeWidget();
      if (launchUri != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _openFromUri(launchUri);
        });
      }
    } catch (error) {
      debugPrint('NotificationTapRouter widget launch setup failed: $error');
    }
  }

  /// Cancels the stream subscriptions.
  Future<void> dispose() async {
    await _openedSub?.cancel();
    await _foregroundSub?.cancel();
    await _widgetSub?.cancel();
    _openedSub = null;
    _foregroundSub = null;
    _widgetSub = null;
  }

  /// Surfaces a foreground push as a tappable banner — the OS doesn't show a
  /// tray notification while the app is open, so this is the foreground analog
  /// of a tray tap. Tapping "Open" routes exactly like a background tap.
  void _showForegroundBanner(RemoteMessage message) {
    final navigatorContext = _navigatorKey.currentContext;
    if (navigatorContext == null) return;
    final messenger = ScaffoldMessenger.maybeOf(navigatorContext);
    if (messenger == null) return;

    final title =
        message.notification?.title ?? message.data['title'] ?? 'Notification';

    messenger.showSnackBar(
      SnackBar(
        content: Text(title),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => _openFromMessage(message),
        ),
      ),
    );
  }

  /// Routes a tapped/opened push: prefer the in-app detail screen via
  /// `notificationId`, then fall back to opening a `url` when that's all the
  /// payload carries.
  Future<void> _openFromMessage(RemoteMessage message) async {
    final data = message.data;

    final notificationId = data['notificationId'];
    if (notificationId is String && notificationId.isNotEmpty) {
      final notification = await _repository.fetchById(uid, notificationId);
      if (notification != null) {
        await _present(notification);
        return;
      }
    }

    final url = data['url'];
    if (url is String && url.isNotEmpty) {
      await _openUrl(url);
    }
  }

  /// Routes a `notifyme://` deep link emitted by the home-screen widget.
  ///
  /// `notifyme://inbox` brings the inbox forward; `notifyme://notification/{id}`
  /// opens that notification's detail screen, falling back to the inbox when the
  /// id is missing or the document can't be resolved (deleted, or another
  /// user's). Anything else is ignored rather than guessed at.
  Future<void> _openFromUri(Uri? uri) async {
    if (uri == null || uri.scheme != _deepLinkScheme) return;

    if (uri.host == _deepLinkInboxHost) {
      _openInbox();
      return;
    }

    if (uri.host == _deepLinkNotificationHost) {
      final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      if (id.isEmpty) {
        _openInbox();
        return;
      }
      final notification = await _repository.fetchById(uid, id);
      if (notification != null) {
        await _present(notification);
      } else {
        _openInbox();
      }
    }
  }

  /// Brings the inbox forward: dismisses any pushed detail screens and selects
  /// the inbox tab (which may not be the one currently showing).
  void _openInbox() {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    navigator.popUntil((route) => route.isFirst);
    homeTabIndex.value = homeInboxTabIndex;
  }

  /// Presents a resolved notification's detail screen. Routed through the
  /// injected [_showDetail] seam in tests; pushes for real otherwise.
  Future<void> _present(AppNotification notification) {
    final show = _showDetail;
    if (show != null) return show(notification);
    return _pushDetail(notification);
  }

  Future<void> _pushDetail(AppNotification notification) async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => NotificationDetailScreen(notification: notification),
      ),
    );
  }

  /// Opens an external URL, refusing anything that isn't plain `http`/`https`
  /// so a crafted payload can't trigger arbitrary schemes (`tel:`, `file:`,
  /// `javascript:`, custom deep links, etc.).
  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return;
    }
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
