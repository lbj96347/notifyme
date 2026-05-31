import 'package:cloud_firestore/cloud_firestore.dart';

import 'notification_model.dart';

/// Owns all Firestore access for the `notifications` collection.
///
/// Keeping the query logic here (rather than inline in widgets) means the UI
/// just consumes a `Stream<List<AppNotification>>` and never references
/// collection names, field names, or ordering — those live in one place and
/// stay in sync with the security rules, which scope every read to the
/// caller's own `uid`.
class NotificationRepository {
  NotificationRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  static const String _collection = 'notifications';

  CollectionReference<Map<String, dynamic>> get _notifications =>
      _firestore.collection(_collection);

  /// Base query: this user's notifications, newest first.
  ///
  /// Filtering by `uid` matches the Firestore rules (a user may only read their
  /// own documents) and ordering by `createdAt` descending puts the most recent
  /// notification at the top of the inbox. Requires a composite index on
  /// (`uid` ==, `createdAt` desc).
  Query<Map<String, dynamic>> _queryForUser(String uid) {
    return _notifications
        .where('uid', isEqualTo: uid)
        .orderBy('createdAt', descending: true);
  }

  /// Live stream of the user's notifications, newest first.
  ///
  /// [limit] caps how many are fetched (defaults to 100) so the inbox stays
  /// bounded; pass a larger value or `null` to remove the cap.
  Stream<List<AppNotification>> watchForUser(
    String uid, {
    int? limit = 100,
  }) {
    var query = _queryForUser(uid);
    if (limit != null) {
      query = query.limit(limit);
    }
    return query.snapshots().map(
          (snapshot) =>
              snapshot.docs.map(AppNotification.fromSnapshot).toList(),
        );
  }

  /// One-shot fetch of the user's notifications, newest first.
  Future<List<AppNotification>> fetchForUser(
    String uid, {
    int? limit = 100,
  }) async {
    var query = _queryForUser(uid);
    if (limit != null) {
      query = query.limit(limit);
    }
    final snapshot = await query.get();
    return snapshot.docs.map(AppNotification.fromSnapshot).toList();
  }

  /// Fetches a single notification by document id, scoped to [uid].
  ///
  /// Used by push-tap handling to resolve an FCM `notificationId` into the
  /// document the detail screen needs. Returns `null` when the document is
  /// missing or belongs to another user — mirroring the Firestore rule that
  /// scopes reads to the signed-in user, so a crafted `notificationId` can't
  /// surface someone else's notification.
  Future<AppNotification?> fetchById(String uid, String notificationId) async {
    final snapshot = await _notifications.doc(notificationId).get();
    final data = snapshot.data();
    if (data == null || data['uid'] != uid) {
      return null;
    }
    return AppNotification.fromSnapshot(snapshot);
  }

  /// Marks a single notification read.
  ///
  /// Updating only `read` (rather than overwriting the document) keeps the
  /// webhook-owned fields intact. The [uid] guard means a caller can never flip
  /// a document that isn't theirs: the update only proceeds when the stored
  /// `uid` matches, mirroring the Firestore rule that scopes writes to the
  /// signed-in user. A no-op when the document is already read or missing.
  Future<void> markRead(String uid, String notificationId) async {
    final ref = _notifications.doc(notificationId);
    final snapshot = await ref.get();
    final data = snapshot.data();
    if (data == null || data['uid'] != uid || data['read'] == true) {
      return;
    }
    await ref.update({'read': true});
  }

  /// Firestore caps a single `WriteBatch` at 500 operations, so unread
  /// notifications are flushed in chunks no larger than this.
  static const int _maxBatchSize = 500;

  /// Marks every unread notification belonging to [uid] as read.
  ///
  /// Queries only the caller's own unread documents — matching the Firestore
  /// rule and skipping anything already read — then commits the `read` flag in
  /// batches of at most [_maxBatchSize] so no single batch exceeds Firestore's
  /// limit. Like [markRead], it touches only `read`, leaving webhook-owned
  /// fields intact. Returns how many notifications were updated.
  Future<int> markAllRead(String uid) async {
    final snapshot = await _notifications
        .where('uid', isEqualTo: uid)
        .where('read', isEqualTo: false)
        .get();

    final docs = snapshot.docs;
    if (docs.isEmpty) return 0;

    for (var start = 0; start < docs.length; start += _maxBatchSize) {
      final end = start + _maxBatchSize < docs.length
          ? start + _maxBatchSize
          : docs.length;
      final batch = _firestore.batch();
      for (final doc in docs.sublist(start, end)) {
        batch.update(doc.reference, {'read': true});
      }
      await batch.commit();
    }

    return docs.length;
  }
}
