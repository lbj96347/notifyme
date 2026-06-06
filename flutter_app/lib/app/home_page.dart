import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../features/auth/auth_service.dart';
import '../features/bookmarks/screens/bookmarks_screen.dart';
import '../features/devices/device_service.dart';
import '../features/notifications/notification_inbox_screen.dart';
import '../features/notifications/notification_tap_router.dart';
import '../features/settings/settings_screen.dart';
import 'home_tab.dart';

/// The app's main screen once the user is signed in.
///
/// Hosts the app's surfaces — the notification inbox, bookmarks, and settings
/// (webhook URL) — behind a bottom navigation bar. The inbox is the default tab
/// since it's where a tapped push lands.
///
/// Both the [authService] and the resolved [user] come from [AuthGate], which
/// only builds this page when a user is signed in. They're passed down to the
/// tabs so the inbox can scope its Firestore query to `user.uid` (via
/// [authService]) and settings can load that user's webhook token.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.authService, required this.user});

  final AuthService authService;
  final User user;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Routes notification taps to the detail screen (or a URL). Created here —
  /// once the user is signed in — so reads are scoped to `user.uid` and the
  /// navigator is mounted by the time a cold-start tap is handled.
  late final NotificationTapRouter _tapRouter;

  /// Requests notification permission and registers this device's FCM token so
  /// the webhook function knows where to push. Created here — once the user is
  /// signed in — and torn down on sign-out via [dispose].
  late final DeviceService _deviceService;

  @override
  void initState() {
    super.initState();
    // A fresh sign-in always lands on the inbox; reset before listening so a
    // tab left selected by a prior session doesn't carry over.
    homeTabIndex.value = homeInboxTabIndex;
    homeTabIndex.addListener(_onTabChanged);

    _tapRouter = NotificationTapRouter(uid: widget.user.uid);
    _tapRouter.register();

    // Prompt for notification permission and store the device token. This is
    // what makes pushes actually arrive; without it the user is never asked and
    // no `devices` document is written. Fire-and-forget — a declined prompt is a
    // no-op inside the service and must not block the UI.
    _deviceService = DeviceService();
    _deviceService.register(widget.user.uid);
  }

  @override
  void dispose() {
    homeTabIndex.removeListener(_onTabChanged);
    _tapRouter.dispose();
    _deviceService.dispose();
    super.dispose();
  }

  /// Rebuilds when the selected tab changes — including changes pushed from a
  /// `notifyme://inbox` deep link outside the widget tree.
  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Built here (not a `const` list) so each tab receives the signed-in user.
    final tabs = <Widget>[
      NotificationInboxScreen(authService: widget.authService),
      BookmarksScreen(authService: widget.authService),
      SettingsScreen(uid: widget.user.uid, authService: widget.authService),
    ];

    final index = homeTabIndex.value;
    return Scaffold(
      body: IndexedStack(index: index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => homeTabIndex.value = i,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: 'Inbox',
          ),
          NavigationDestination(
            icon: Icon(Icons.bookmark_border),
            selectedIcon: Icon(Icons.bookmark),
            label: 'Bookmarks',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
