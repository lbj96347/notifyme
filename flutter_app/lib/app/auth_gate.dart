// AuthGate — routes between the sign-in screen and the app based on auth state.
//
// Listens to [AuthService.authStateChanges]. While the first auth state is
// resolving we show a spinner; once resolved we show [AuthScreen] (signed out)
// or [HomePage] (signed in). Because it's stream-driven, sign-in and sign-out
// transition the UI automatically with no manual navigation.
//
// On a *restored* session (the app relaunching while already signed in) the
// sign-in/sign-up code paths never run, so we re-assert the user's profile here
// via [AuthService.ensureUserDocument]. That backfills the webhook token for any
// account that predates it or whose first write was rejected (e.g. before the
// Firestore rules were deployed), so the Settings screen stops showing "your
// webhook URL is being set up" without the user having to sign out and back in.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../features/auth/auth_screen.dart';
import '../features/auth/auth_service.dart';
import 'home_page.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.authService});

  final AuthService authService;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // The uid we've already ensured a profile for, so the StreamBuilder's repeated
  // rebuilds don't fire redundant transactions. Reset on sign-out.
  String? _ensuredUid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: widget.authService.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = snapshot.data;
        if (user == null) {
          _ensuredUid = null;
          return AuthScreen(authService: widget.authService);
        }

        if (_ensuredUid != user.uid) {
          _ensuredUid = user.uid;
          // Fire-and-forget: the Settings screen streams the user doc, so the
          // token appears as soon as the write lands. We don't block the UI on
          // the backfill; swallow+log failures (e.g. rules not yet deployed) so
          // they don't surface as an unhandled async error — the Settings
          // screen's "being set up" state already communicates the pending URL.
          widget.authService.ensureUserDocument(user).catchError(
                (Object e) => debugPrint('ensureUserDocument failed: $e'),
              );
        }

        return HomePage(authService: widget.authService, user: user);
      },
    );
  }
}
