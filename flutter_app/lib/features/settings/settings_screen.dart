// Settings — shows the user their personal webhook URL.
//
// The webhook URL is NotifyMe's primary call to action: the user copies it into
// Claude Code, n8n, a CI job, a `curl`, etc. so those systems can push to their
// phone. This screen loads the `webhookToken` from `users/{uid}` (minted at
// sign-in by AuthService), builds the full URL for *this* deployment's Firebase
// project (see [WebhookUrlBuilder]), and offers one-tap copy-to-clipboard.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_service.dart';
import '../widget/home_widget_service.dart';
import 'webhook_url.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.uid,
    required this.authService,
    this.firestore,
    this.urlBuilder,
    this.projectId,
  });

  /// The signed-in user whose webhook token to show.
  final String uid;

  /// Used to sign the user out. [AuthGate] reacts to the auth-state change and
  /// routes back to the sign-in screen automatically.
  final AuthService authService;

  /// Firestore instance; defaults to the singleton. Injectable for tests.
  final FirebaseFirestore? firestore;

  /// Builds the webhook URL from a token + project ID. Defaults to the
  /// build-time configuration. Injectable for tests.
  final WebhookUrlBuilder? urlBuilder;

  /// The Firebase project ID this app is deployed against. Defaults to the one
  /// baked into `firebase_options.dart` (`Firebase.app().options.projectId`).
  /// Injectable for tests so they need not initialize a Firebase app.
  final String? projectId;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final FirebaseFirestore _firestore;
  late final WebhookUrlBuilder _urlBuilder;
  late final String _projectId;

  @override
  void initState() {
    super.initState();
    _firestore = widget.firestore ?? FirebaseFirestore.instance;
    _urlBuilder = widget.urlBuilder ?? WebhookUrlBuilder.fromEnvironment();
    _projectId = widget.projectId ?? Firebase.app().options.projectId;
  }

  /// Stream the user document so a token backfilled after first sign-in (see
  /// [AuthService.ensureUserDocument]) appears without a manual refresh.
  Stream<DocumentSnapshot<Map<String, dynamic>>> get _userDoc =>
      _firestore.collection('users').doc(widget.uid).snapshots();

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Webhook URL copied to clipboard')),
    );
  }

  /// Confirm, then sign out. [AuthGate] streams auth state, so signing out
  /// routes back to the sign-in screen without manual navigation here.
  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'You can sign back in any time. Your webhook URL stays the same.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.authService.signOut();
      // Wipe the home-screen widget's mirrored notifications so a signed-out
      // device doesn't leave the previous user's data on the lock/home screen.
      // Best-effort: clear() swallows its own errors.
      await HomeWidgetService().clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not sign out: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _userDoc,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _Message(
              icon: Icons.error_outline,
              text: 'Could not load your webhook URL. Please try again.',
              isError: true,
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final token = snapshot.data?.data()?['webhookToken'];
          if (token is! String || token.isEmpty) {
            // The token is minted at sign-in; if it isn't there yet, the doc is
            // still being written. Tell the user rather than show a broken URL.
            return const _Message(
              icon: Icons.hourglass_empty,
              text: 'Your webhook URL is being set up. Check back in a moment.',
            );
          }

          final url = _urlBuilder.build(projectId: _projectId, token: token);
          return _WebhookSection(url: url, onCopy: () => _copy(url));
        },
      ),
    );
  }
}

/// The webhook URL card plus copy button and usage guidance.
class _WebhookSection extends StatelessWidget {
  const _WebhookSection({required this.url, required this.onCopy});

  final String url;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Your webhook URL', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'POST notifications to this URL and they arrive on your phone. '
          'Keep it secret — anyone with this URL can notify you.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              url,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onCopy,
          icon: const Icon(Icons.copy),
          label: const Text('Copy to clipboard'),
        ),
        const SizedBox(height: 24),
        Text('Quick test', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          'Send yourself a test notification from a terminal:',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              "curl -X POST '$url' \\\n"
              "  -H 'Content-Type: application/json' \\\n"
              '  -d \'{"title":"Hello","message":"It works!",'
              '"category":"test","status":"success"}\'',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Centered icon + message used for the loading-error and pending states.
class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.isError = false,
  });

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.error : theme.colorScheme.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: color),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
