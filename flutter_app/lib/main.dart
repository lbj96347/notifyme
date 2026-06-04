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
import 'shared/retro_palette.dart';

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
    final options = DefaultFirebaseOptions.currentPlatform;
    // Guard against the committed placeholder values. The native iOS Firebase
    // SDK raises an NSException from +[FIRApp addAppToAppDictionary:] when the
    // appId doesn't match the expected format — that's an Objective-C exception
    // which bypasses this try/catch and SIGABRTs the process. Detect the
    // template values up-front so we render the diagnostic screen instead.
    if (options.appId.startsWith('YOUR_') ||
        options.apiKey.startsWith('YOUR_')) {
      throw StateError(
        'firebase_options.dart still contains placeholder values. '
        'Run `flutterfire configure` to generate real values for your project.',
      );
    }
    await Firebase.initializeApp(options: options);
    firebaseReady = true;
  } catch (e) {
    firebaseError = e.toString();
  }

  runApp(
    NotifyMeApp(firebaseReady: firebaseReady, firebaseError: firebaseError),
  );
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
    // AuthService touches FirebaseAuth.instance in its constructor, which
    // throws [core/no-app] when Firebase failed to initialize. Only construct
    // it on the happy path so the diagnostic screen can still render.
    final authService = firebaseReady ? AuthService() : null;

    return MaterialApp(
      title: 'NotifyMe',
      debugShowCheckedModeBanner: false,
      // Shared key so push-tap handling can navigate from outside the widget
      // tree — taps arrive via FCM streams (see NotificationTapRouter), not the
      // UI, so there's no BuildContext to navigate from otherwise.
      navigatorKey: notificationNavigatorKey,
      // The app is dark-forward to match the retro pager icon, so the retro
      // palette drives both slots. See [RetroPalette] for the sampled colors.
      theme: ThemeData(
        colorScheme: RetroPalette.colorScheme,
        scaffoldBackgroundColor: RetroPalette.background,
        // Apply the retro LCD/terminal typeface app-wide. Setting fontFamily
        // (rather than rebuilding the TextTheme) keeps every M3 text style's
        // size, weight, and spacing intact, so only the glyphs change — no
        // layout shifts. See [RetroPalette.fontFamily].
        fontFamily: RetroPalette.fontFamily,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: RetroPalette.colorScheme,
        scaffoldBackgroundColor: RetroPalette.background,
        fontFamily: RetroPalette.fontFamily,
        useMaterial3: true,
      ),
      // When Firebase is configured, AuthGate decides between the sign-in
      // screen and the app. Otherwise we show a clear diagnostic screen.
      home: firebaseReady
          ? AuthGate(authService: authService!)
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
              Icon(
                Icons.error_outline,
                size: 72,
                color: theme.colorScheme.error,
              ),
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
