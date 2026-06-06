// Mirrors the latest notifications into the `home_widget` shared container so a
// native home-screen widget (iOS WidgetKit / Android App Widget) can render them
// without touching Firebase itself.
//
// The widget process can't reach Firestore or hold the user's auth session, so
// the app is the only thing that can feed it. After each inbox load/refresh the
// app calls [HomeWidgetService.sync] with the newest notifications; the service
// trims them to a bounded set, serializes the fields the widget needs into a
// single JSON string, writes it to the App Group container, and asks the OS to
// redraw the widget.
//
// Wire contract written to shared storage (read by the native widget):
//
// - `notifyme_widget_items`  — JSON array (newest-first) of item objects, each:
//   `{ id, title, body, status, category, receivedAt, read, url }`.
//     - `body` is a short preview (see [_bodyPreviewLimit]); `receivedAt` is
//       epoch milliseconds or `null`; `url` is omitted (absent key) when unset.
// - `notifyme_widget_unread` — int, count of unread items in the synced set.
// - `notifyme_widget_updated` — epoch milliseconds the data was last written.
//
// The App Group id and key names must match the native side
// (`UserDefaults(suiteName:)` on iOS). See `ios/WIDGET_SETUP.md`.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../notifications/notification_model.dart';

/// Thin seam over the `home_widget` package's static API.
///
/// `home_widget` exposes only static methods, which can't be faked in a unit
/// test; routing every call through this interface lets [HomeWidgetService] take
/// an in-memory fake while [_DefaultHomeWidgetClient] wires the real package in
/// production.
abstract class HomeWidgetClient {
  /// Binds subsequent reads/writes to the shared App Group container.
  Future<void> setAppGroupId(String groupId);

  /// Persists [value] under [key] in the shared container (a `null` clears it).
  Future<void> saveWidgetData(String key, String? value);

  /// Asks the OS to re-render the widget after data changed.
  Future<void> updateWidget({String? iOSName, String? androidName});
}

/// Production [HomeWidgetClient] backed by the real `home_widget` package.
class _DefaultHomeWidgetClient implements HomeWidgetClient {
  const _DefaultHomeWidgetClient();

  @override
  Future<void> setAppGroupId(String groupId) =>
      HomeWidget.setAppGroupId(groupId);

  @override
  Future<void> saveWidgetData(String key, String? value) =>
      HomeWidget.saveWidgetData<String>(key, value);

  @override
  Future<void> updateWidget({String? iOSName, String? androidName}) =>
      HomeWidget.updateWidget(iOSName: iOSName, androidName: androidName);
}

/// Pushes the latest notifications into the home-screen widget's shared storage.
///
/// Stateless apart from its injected [HomeWidgetClient]; call [sync] whenever the
/// inbox's newest rows change. All work is best-effort: a failure to write widget
/// data must never break the inbox, so [sync] swallows and logs errors rather
/// than rethrowing (mirroring the best-effort FCM push on the backend).
class HomeWidgetService {
  HomeWidgetService({
    HomeWidgetClient? client,
    this.appGroupId = defaultAppGroupId,
    this.iOSWidgetName = defaultIosWidgetName,
    this.androidWidgetName = defaultAndroidWidgetName,
    this.maxItems = defaultMaxItems,
  }) : _client = client ?? const _DefaultHomeWidgetClient();

  final HomeWidgetClient _client;

  /// App Group / shared-container id. Must match `ios/Runner/Runner.entitlements`
  /// and the widget's `UserDefaults(suiteName:)`. See `ios/WIDGET_SETUP.md`.
  final String appGroupId;

  /// iOS WidgetKit widget kind passed to `updateWidget`.
  final String iOSWidgetName;

  /// Android App Widget provider class name passed to `updateWidget`.
  final String androidWidgetName;

  /// How many notifications at most are written to the widget. The widget only
  /// shows a handful, and the shared container shouldn't grow unbounded.
  final int maxItems;

  static const String defaultAppGroupId = 'group.com.asktobuild.notifyme';
  static const String defaultIosWidgetName = 'NotifyMeWidget';
  static const String defaultAndroidWidgetName = 'NotifyMeWidgetProvider';
  static const int defaultMaxItems = 10;

  /// Storage keys in the shared container. Public so the native widget docs and
  /// any future tests reference one source of truth.
  static const String itemsKey = 'notifyme_widget_items';
  static const String unreadKey = 'notifyme_widget_unread';
  static const String updatedKey = 'notifyme_widget_updated';

  /// Longest message preview stored per item; the widget has little room and the
  /// full body lives in the app.
  static const int _bodyPreviewLimit = 140;

  bool _appGroupReady = false;

  /// Writes [notifications] (assumed newest-first) into the widget's shared
  /// storage and triggers a redraw.
  ///
  /// Trims to [maxItems], serializes each to the wire contract above, and records
  /// the unread count and a write timestamp. Best-effort: any error is logged and
  /// swallowed so a widget-storage failure never disrupts the inbox.
  ///
  /// Pass [now] to stamp `notifyme_widget_updated` deterministically in tests;
  /// it defaults to the wall clock.
  Future<void> sync(
    List<AppNotification> notifications, {
    DateTime? now,
  }) async {
    try {
      await _ensureAppGroup();

      final items = notifications.take(maxItems).map(_toWidgetItem).toList();
      final unread = items.where((item) => item['read'] == false).length;
      final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;

      await _client.saveWidgetData(itemsKey, jsonEncode(items));
      await _client.saveWidgetData(unreadKey, unread.toString());
      await _client.saveWidgetData(updatedKey, stamp.toString());

      await _client.updateWidget(
        iOSName: iOSWidgetName,
        androidName: androidWidgetName,
      );
    } catch (error, stackTrace) {
      // Best-effort: the widget mirror is a convenience, never a correctness
      // requirement, so a failure here must not surface to the inbox.
      debugPrint('HomeWidgetService.sync failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// Clears the widget's shared data (e.g. on sign-out) and redraws it empty.
  Future<void> clear({DateTime? now}) async {
    try {
      await _ensureAppGroup();
      final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
      await _client.saveWidgetData(itemsKey, jsonEncode(const <dynamic>[]));
      await _client.saveWidgetData(unreadKey, '0');
      await _client.saveWidgetData(updatedKey, stamp.toString());
      await _client.updateWidget(
        iOSName: iOSWidgetName,
        androidName: androidWidgetName,
      );
    } catch (error, stackTrace) {
      debugPrint('HomeWidgetService.clear failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// Binds the App Group once per process; repeated [sync] calls are cheap.
  Future<void> _ensureAppGroup() async {
    if (_appGroupReady) return;
    await _client.setAppGroupId(appGroupId);
    _appGroupReady = true;
  }

  /// Serializes one notification to the widget wire contract.
  ///
  /// `category` doubles as the source/origin label (`claude`, `ci`, `n8n`, …);
  /// `url` is left out entirely when absent so the widget can treat a present key
  /// as "tappable". `receivedAt` is epoch milliseconds (or `null` while a freshly
  /// written `serverTimestamp()` resolves).
  Map<String, dynamic> _toWidgetItem(AppNotification n) {
    return <String, dynamic>{
      'id': n.id,
      'title': n.title,
      'body': _preview(n.message),
      'status': n.status,
      'category': n.category,
      'receivedAt': n.createdAt?.millisecondsSinceEpoch,
      'read': n.read,
      if (n.url != null && n.url!.isNotEmpty) 'url': n.url,
    };
  }

  /// Collapses whitespace and truncates a message to [_bodyPreviewLimit] chars,
  /// appending an ellipsis when it was cut.
  String _preview(String message) {
    final collapsed = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= _bodyPreviewLimit) return collapsed;
    return '${collapsed.substring(0, _bodyPreviewLimit).trimRight()}…';
  }
}
