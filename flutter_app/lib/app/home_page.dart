import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../features/auth/auth_service.dart';
import '../features/notifications/notification_inbox_screen.dart';
import '../features/notifications/notification_tap_router.dart';
import '../features/settings/settings_screen.dart';

/// The app's main screen once the user is signed in.
///
/// Hosts the two MVP surfaces — the notification inbox and settings (webhook
/// URL) — behind a bottom navigation bar. The inbox is the default tab since
/// it's where a tapped push lands.
///
/// Both the [authService] and the resolved [user] come from [AuthGate], which
/// only builds this page when a user is signed in. They're passed down to the
/// tabs so the inbox can scope its Firestore query to `user.uid` (via
/// [authService]) and settings can load that user's webhook token.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.authService,
    required this.user,
  });

  final AuthService authService;
  final User user;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  /// Routes notification taps to the detail screen (or a URL). Created here —
  /// once the user is signed in — so reads are scoped to `user.uid` and the
  /// navigator is mounted by the time a cold-start tap is handled.
  late final NotificationTapRouter _tapRouter;

  @override
  void initState() {
    super.initState();
    _tapRouter = NotificationTapRouter(uid: widget.user.uid);
    _tapRouter.register();
  }

  @override
  void dispose() {
    _tapRouter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Built here (not a `const` list) so each tab receives the signed-in user.
    final tabs = <Widget>[
      NotificationInboxScreen(authService: widget.authService),
      SettingsScreen(uid: widget.user.uid),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: 'Inbox',
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
