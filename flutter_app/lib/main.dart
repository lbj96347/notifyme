// NotifyMe — Flutter client entrypoint.
//
// This file boots Firebase and renders the app. The app is designed to be
// *self-hosted*: each user deploys it against their own Firebase project, so we
// never hardcode project IDs here. Instead, configuration lives in the generated
// `firebase_options.dart` (see below), produced by `flutterfire configure` and
// deliberately kept out of source control.

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'app/auth_gate.dart';
import 'features/auth/auth_service.dart';
import 'features/notifications/notification_tap_router.dart';

// GENERATED FILE — not committed. Run `flutterfire configure` to create it.
// A committed template lives at `firebase_options.dart.example` so contributors
// know the expected shape. We import the real file here; if it's missing the
// build will fail with a clear "uri doesn't exist" error pointing the developer
// at the setup step (documented in docs/FIREBASE_SETUP.md).
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Attempt Firebase initialization. We keep this resilient so the app can at
  // least render a diagnostic screen if configuration is missing or invalid,
  // rather than crashing to a black screen on launch.
  bool firebaseReady = false;
  String? firebaseError;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firebaseReady = true;
  } catch (e) {
    firebaseError = e.toString();
  }

  runApp(NotifyMeApp(firebaseReady: firebaseReady, firebaseError: firebaseError));
}

class NotifyMeApp extends StatelessWidget {
  const NotifyMeApp({
    super.key,
    required this.firebaseReady,
    this.firebaseError,
  });

  final bool firebaseReady;
  final String? firebaseError;

  @override
  Widget build(BuildContext context) {
    // AuthService is a stateless wrapper over Firebase singletons, so creating
    // it here (rather than as a field) keeps this constructor `const`.
    final authService = AuthService();

    return MaterialApp(
      title: 'NotifyMe',
      debugShowCheckedModeBanner: false,
      // Shared key so push-tap handling can navigate from outside the widget
      // tree — taps arrive via FCM streams (see NotificationTapRouter), not the
      // UI, so there's no BuildContext to navigate from otherwise.
      navigatorKey: notificationNavigatorKey,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2563EB),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF2563EB),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      // When Firebase is configured, AuthGate decides between the sign-in
      // screen and the app. Otherwise we show a clear diagnostic screen.
      home: firebaseReady
          ? AuthGate(authService: authService)
          : _FirebaseErrorScreen(error: firebaseError),
    );
  }
}

/// Shown when Firebase failed to initialize (typically missing configuration).
class _FirebaseErrorScreen extends StatelessWidget {
  const _FirebaseErrorScreen({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('NotifyMe'), centerTitle: true),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.error_outline, size: 72, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                'Firebase not configured',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                error ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Run `flutterfire configure` — see docs/FIREBASE_SETUP.md.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
