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
import 'package:url_launcher/url_launcher.dart';

import 'notification_detail_screen.dart';
import 'notification_repository.dart';

/// Navigator key for the root MaterialApp, used to navigate from tap handlers
/// that run without a BuildContext. Installed in `main.dart`.
final GlobalKey<NavigatorState> notificationNavigatorKey =
    GlobalKey<NavigatorState>();

/// Wires Firebase Messaging taps to in-app navigation.
///
/// Construct once the user is signed in (so reads are scoped to a known [uid]
/// and the navigator exists) and call [register]. Call [dispose] on sign-out to
/// drop the stream subscriptions.
class NotificationTapRouter {
  NotificationTapRouter({
    required this.uid,
    FirebaseMessaging? messaging,
    NotificationRepository? repository,
    GlobalKey<NavigatorState>? navigatorKey,
  })  : _messaging = messaging ?? FirebaseMessaging.instance,
        _repository = repository ?? NotificationRepository(),
        _navigatorKey = navigatorKey ?? notificationNavigatorKey;

  final String uid;
  final FirebaseMessaging _messaging;
  final NotificationRepository _repository;
  final GlobalKey<NavigatorState> _navigatorKey;

  StreamSubscription<RemoteMessage>? _openedSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;

  /// Sets up tap handling for all three app states. Safe to call once per
  /// sign-in; repeated calls replace any prior subscriptions.
  Future<void> register() async {
    await dispose();

    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen(_openFromMessage);
    _foregroundSub = FirebaseMessaging.onMessage.listen(_showForegroundBanner);

    // A tap that cold-started the app from a terminated state. Deferred to the
    // next frame so the first route (HomePage) is mounted before we push onto
    // the navigator.
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openFromMessage(initialMessage);
      });
    }
  }

  /// Cancels the stream subscriptions.
  Future<void> dispose() async {
    await _openedSub?.cancel();
    await _foregroundSub?.cancel();
    _openedSub = null;
    _foregroundSub = null;
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
        final navigator = _navigatorKey.currentState;
        if (navigator != null) {
          await navigator.push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  NotificationDetailScreen(notification: notification),
            ),
          );
        }
        return;
      }
    }

    final url = data['url'];
    if (url is String && url.isNotEmpty) {
      await _openUrl(url);
    }
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
