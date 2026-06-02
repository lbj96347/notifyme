import 'package:cloud_firestore/cloud_firestore.dart';

import '../../shared/notification_category.dart';
import '../../shared/notification_status.dart';

/// An immutable view of a single `notifications/{id}` document.
///
/// The field set mirrors the shared webhook payload contract
/// (`title`, `message`, `category`, `status`, `url`) plus the server-managed
/// fields the app needs for the inbox (`uid`, `read`, `createdAt`). Parsing is
/// tolerant: missing or wrong-typed fields fall back to sensible defaults so a
/// malformed document never crashes the list.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.uid,
    required this.title,
    required this.message,
    required this.category,
    required this.status,
    required this.read,
    this.bookmarked = false,
    this.url,
    this.createdAt,
  });

  final String id;
  final String uid;
  final String title;
  final String message;

  /// Organizes the inbox, e.g. `claude`, `ci`, `n8n`.
  final String category;

  /// Maps to a color in the UI: success (green), error (red), warning
  /// (yellow), info (blue).
  final String status;

  /// Whether the user has marked this notification read.
  final bool read;

  /// Whether the user has bookmarked (starred) this notification so it stays
  /// easy to find in the Bookmarks tab.
  final bool bookmarked;

  /// Optional deep link; when set the notification is tappable.
  final String? url;

  /// Server timestamp the notification was written. May be `null` briefly
  /// while a freshly written document's `serverTimestamp()` resolves.
  final DateTime? createdAt;

  /// Builds a model from a Firestore document snapshot.
  factory AppNotification.fromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    final createdAt = data['createdAt'];
    return AppNotification(
      id: doc.id,
      uid: data['uid'] as String? ?? '',
      title: data['title'] as String? ?? '',
      message: data['message'] as String? ?? '',
      category: data['category'] as String? ?? defaultNotificationCategory,
      status: data['status'] as String? ?? NotificationStatus.info.name,
      read: data['read'] as bool? ?? false,
      bookmarked: data['bookmarked'] as bool? ?? false,
      url: data['url'] as String?,
      createdAt: createdAt is Timestamp ? createdAt.toDate() : null,
    );
  }
}
