import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../shared/notification_status.dart';
import '../auth/auth_service.dart';
import 'notification_date_group.dart';
import 'notification_model.dart';
import 'notification_repository.dart';

/// Full view of a single notification: title, message, and a metadata block
/// (category, status, time, read state) plus an "Open link" action when the
/// payload carried a [AppNotification.url].
///
/// Opening the screen marks an unread notification read — viewing the detail is
/// the natural "I've seen this" signal, so the inbox's unread tint clears once
/// the user comes back. The write is scoped to the signed-in user's own
/// document (see [NotificationRepository.markRead]).
class NotificationDetailScreen extends StatefulWidget {
  const NotificationDetailScreen({
    super.key,
    required this.notification,
    NotificationRepository? repository,
    AuthService? authService,
  }) : _repository = repository,
       _authService = authService;

  final AppNotification notification;
  final NotificationRepository? _repository;
  final AuthService? _authService;

  @override
  State<NotificationDetailScreen> createState() =>
      _NotificationDetailScreenState();
}

class _NotificationDetailScreenState extends State<NotificationDetailScreen> {
  /// Tracks read state locally so the metadata block reflects the mark-read
  /// without needing the inbox stream to round-trip back into this screen.
  late bool _read = widget.notification.read;

  /// Tracks bookmark state locally so the AppBar star reflects taps immediately,
  /// without waiting for the inbox stream to round-trip back into this screen.
  late bool _bookmarked = widget.notification.bookmarked;

  @override
  void initState() {
    super.initState();
    _markReadIfNeeded();
  }

  Future<void> _markReadIfNeeded() async {
    final notification = widget.notification;
    if (notification.read) return;
    final user = (widget._authService ?? AuthService()).currentUser;
    if (user == null) return;
    final repository = widget._repository ?? NotificationRepository();
    await repository.markRead(user.uid, notification.id);
    if (mounted) {
      setState(() => _read = true);
    }
  }

  /// Stars/unstars this notification. Flips local state optimistically so the
  /// AppBar icon responds instantly, then persists via the repository (scoped to
  /// the signed-in user); on failure it rolls back and surfaces a SnackBar.
  Future<void> _toggleBookmark() async {
    final user = (widget._authService ?? AuthService()).currentUser;
    if (user == null) return;
    final repository = widget._repository ?? NotificationRepository();
    final next = !_bookmarked;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _bookmarked = next);
    try {
      await repository.setBookmark(
        user.uid,
        widget.notification.id,
        bookmarked: next,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _bookmarked = !next);
        messenger.showSnackBar(
          const SnackBar(content: Text('Couldn’t update bookmark.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final notification = widget.notification;
    final theme = Theme.of(context);
    final status = NotificationStatus.fromWire(notification.status);
    final url = notification.url;
    final hasUrl = url != null && url.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification'),
        actions: [
          IconButton(
            icon: Icon(_bookmarked ? Icons.bookmark : Icons.bookmark_border),
            tooltip: _bookmarked ? 'Remove bookmark' : 'Bookmark',
            onPressed: _toggleBookmark,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          // Status + category at a glance.
          Row(
            children: [
              _StatusBadge(status: status, label: notification.status),
              const SizedBox(width: 8),
              _CategoryChip(label: notification.category, color: status.color),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            notification.title.isEmpty ? '(no title)' : notification.title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (notification.message.isNotEmpty) ...[
            const SizedBox(height: 12),
            SelectableText(
              notification.message,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
            ),
          ],
          const SizedBox(height: 28),
          if (hasUrl) ...[
            FilledButton.icon(
              onPressed: () => _openUrl(context, url),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open link'),
            ),
            const SizedBox(height: 28),
          ],
          Divider(color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 8),
          _MetaRow(
            icon: Icons.label_outline,
            label: 'Category',
            value: notification.category,
          ),
          _MetaRow(
            icon: Icons.circle,
            iconColor: status.color,
            label: 'Status',
            value: notification.status,
          ),
          _MetaRow(
            icon: Icons.schedule,
            label: 'Received',
            value: _formatTimestamp(notification.createdAt),
          ),
          _MetaRow(
            icon: _read
                ? Icons.mark_email_read_outlined
                : Icons.mark_email_unread_outlined,
            label: 'State',
            value: _read ? 'Read' : 'Unread',
          ),
          if (hasUrl) _MetaRow(icon: Icons.link, label: 'Link', value: url),
        ],
      ),
    );
  }

  /// Launches [url] in an external app/browser, surfacing a SnackBar if it
  /// can't be opened (malformed URL, no handler installed).
  Future<void> _openUrl(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(url.trim());
    var launched = false;
    if (uri != null) {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (!launched) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn’t open $url')));
    }
  }

  /// "May 28, 2026 at 14:30" in the device's local time, or an em dash when the
  /// server timestamp hasn't resolved yet.
  static String _formatTimestamp(DateTime? dt) {
    if (dt == null) return '—';
    final local = dt.toLocal();
    return '${NotificationDateGroup.formatDate(local)} '
        'at ${NotificationDateGroup.formatTime(local)}';
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, required this.label});

  final NotificationStatus status;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: status.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: status.color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
    this.iconColor,
  });

  final IconData icon;
  final Color? iconColor;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: iconColor ?? theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
