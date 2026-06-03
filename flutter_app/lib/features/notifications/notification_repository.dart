import 'package:cloud_firestore/cloud_firestore.dart';

import 'notification_model.dart';

/// One page of the inbox plus the metadata a caller needs to fetch the next one.
///
/// [notifications] is the page itself (newest-first). [cursor] is the last
/// document of the page — pass it back as `startAfter` to fetch the page that
/// follows; it's `null` only when the page is empty. [hasMore] says whether a
/// further page exists, so the UI knows when to stop requesting more (and can
/// hide its "load more" affordance) without firing one last empty query.
class NotificationPage {
  const NotificationPage({
    required this.notifications,
    required this.cursor,
    required this.hasMore,
  });

  /// An empty terminal page: nothing loaded, no cursor, nothing more to fetch.
  static const NotificationPage empty = NotificationPage(
    notifications: <AppNotification>[],
    cursor: null,
    hasMore: false,
  );

  final List<AppNotification> notifications;

  /// The last document of this page, used as the `startAfter` cursor for the
  /// next [NotificationRepository.fetchPage] call. `null` when the page is empty.
  final DocumentSnapshot<Map<String, dynamic>>? cursor;

  /// Whether at least one more notification exists after this page.
  final bool hasMore;
}

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
  Stream<List<AppNotification>> watchForUser(String uid, {int? limit = 100}) {
    var query = _queryForUser(uid);
    if (limit != null) {
      query = query.limit(limit);
    }
    return query.snapshots().map(
      (snapshot) => snapshot.docs.map(AppNotification.fromSnapshot).toList(),
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

  /// Default number of notifications fetched per page by [fetchPage].
  static const int defaultPageSize = 30;

  /// Fetches one page of the user's notifications, newest first, for an
  /// infinite-scroll inbox.
  ///
  /// Pass `startAfter: null` (the default) for the first page; for each
  /// subsequent page, pass the previous page's [NotificationPage.cursor]. The
  /// cursor is a [DocumentSnapshot] so Firestore's `startAfterDocument` can
  /// resume exactly after it — stable even if documents are inserted between
  /// fetches, unlike an offset.
  ///
  /// To know whether more pages exist without a second count query, this asks
  /// Firestore for one extra document ([pageSize] + 1). If that extra row comes
  /// back, [NotificationPage.hasMore] is `true` and the extra is trimmed off the
  /// returned page; otherwise this is the last page.
  ///
  /// Uses the same `(uid ==, createdAt desc)` query as the inbox stream, so it
  /// relies on the same composite index.
  Future<NotificationPage> fetchPage(
    String uid, {
    int pageSize = defaultPageSize,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    var query = _queryForUser(uid).limit(pageSize + 1);
    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }
    final docs = (await query.get()).docs;
    if (docs.isEmpty) {
      return NotificationPage.empty;
    }

    final hasMore = docs.length > pageSize;
    final pageDocs = hasMore ? docs.sublist(0, pageSize) : docs;
    return NotificationPage(
      notifications: pageDocs.map(AppNotification.fromSnapshot).toList(),
      cursor: pageDocs.last,
      hasMore: hasMore,
    );
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

  /// Sets the bookmark (starred) state of a single notification.
  ///
  /// Like [markRead], it touches only the one field — leaving webhook-owned
  /// fields and `read` intact — and the [uid] guard means a caller can never
  /// flip a document that isn't theirs (mirroring the Firestore rule that
  /// scopes writes to the signed-in user). A no-op when the document is missing,
  /// belongs to another user, or is already in the requested state.
  Future<void> setBookmark(
    String uid,
    String notificationId, {
    required bool bookmarked,
  }) async {
    final ref = _notifications.doc(notificationId);
    final snapshot = await ref.get();
    final data = snapshot.data();
    if (data == null ||
        data['uid'] != uid ||
        (data['bookmarked'] as bool? ?? false) == bookmarked) {
      return;
    }
    await ref.update({'bookmarked': bookmarked});
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
