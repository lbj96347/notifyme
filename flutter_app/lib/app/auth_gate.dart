// AuthGate — routes between the sign-in screen and the app based on auth state.
//
// Listens to [AuthService.authStateChanges]. While the first auth state is
// resolving we show a spinner; once resolved we show [AuthScreen] (signed out)
// or [HomePage] (signed in). Because it's stream-driven, sign-in and sign-out
// transition the UI automatically with no manual navigation.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../features/auth/auth_screen.dart';
import '../features/auth/auth_service.dart';
import 'home_page.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.authService});

  final AuthService authService;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: authService.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = snapshot.data;
        if (user == null) {
          return AuthScreen(authService: authService);
        }
        return HomePage(authService: authService, user: user);
      },
    );
  }
}
