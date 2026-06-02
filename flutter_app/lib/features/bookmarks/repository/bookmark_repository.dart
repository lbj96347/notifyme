import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/bookmark.dart';

/// Owns all Firestore access for the per-user `bookmarks` subcollection at
/// `users/{uid}/bookmarks/{bookmarkId}`.
///
/// Keeping the query logic here (rather than inline in widgets) means the UI
/// just consumes a `Stream<List<Bookmark>>` and never references collection
/// names, field names, or ordering — those live in one place and stay in sync
/// with the security rules.
///
/// Ownership is *structural*: each bookmark lives under its owner's `users/{uid}`
/// document, so the `{uid}` path segment scopes every read and write. The
/// security rules grant access by matching that segment, the model never has to
/// be filtered by `uid`, and the newest-first query needs no composite index
/// (an unfiltered `orderBy` uses the automatic single-field index). Writes go
/// through plain field maps so the stored shape matches what [Bookmark] parses
/// back.
class BookmarkRepository {
  BookmarkRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  static const String _usersCollection = 'users';
  static const String _bookmarksSubcollection = 'bookmarks';

  /// The signed-in user's bookmarks subcollection: `users/{uid}/bookmarks`.
  CollectionReference<Map<String, dynamic>> _bookmarksFor(String uid) =>
      _firestore
          .collection(_usersCollection)
          .doc(uid)
          .collection(_bookmarksSubcollection);

  /// Live stream of the user's bookmarks, newest first. (Read.)
  ///
  /// Scoped by the subcollection path, so no `uid` filter is needed and the
  /// `createdAt` ordering rides the automatic single-field index. [limit] caps
  /// how many are fetched (defaults to 100) so the list stays bounded; pass a
  /// larger value or `null` to remove the cap.
  Stream<List<Bookmark>> watchForUser(String uid, {int? limit = 100}) {
    Query<Map<String, dynamic>> query = _bookmarksFor(
      uid,
    ).orderBy('createdAt', descending: true);
    if (limit != null) {
      query = query.limit(limit);
    }
    return query.snapshots().map(
      (snapshot) => snapshot.docs.map(Bookmark.fromSnapshot).toList(),
    );
  }

  /// One-shot fetch of a single bookmark by id, or `null` if it doesn't exist.
  /// (Read.) Scoped to [uid] by the subcollection path.
  Future<Bookmark?> fetchById(String uid, String bookmarkId) async {
    final snapshot = await _bookmarksFor(uid).doc(bookmarkId).get();
    if (!snapshot.exists) return null;
    return Bookmark.fromSnapshot(snapshot);
  }

  /// Saves a new bookmark for [uid] and returns its generated id. (Create.)
  ///
  /// The caller supplies only [title] and [url]; `createdAt`/`updatedAt` are
  /// stamped by the server so ordering is consistent across devices and clock
  /// skew. The `uid` field is written from the trusted argument (matching the
  /// owning path segment) so a document re-parses to the same owner.
  Future<String> add(
    String uid, {
    required String title,
    required String url,
  }) async {
    final now = FieldValue.serverTimestamp();
    final ref = await _bookmarksFor(uid).add(<String, dynamic>{
      'uid': uid,
      'title': title,
      'url': url,
      'createdAt': now,
      'updatedAt': now,
    });
    return ref.id;
  }

  /// Edits an existing bookmark's [title] and/or [url], stamping `updatedAt`
  /// server-side. (Update.)
  ///
  /// Only the fields passed are touched, leaving `createdAt` and `lastCheckedAt`
  /// intact. A no-op when neither field is supplied. Scoped to [uid] by the
  /// subcollection path; throws if [bookmarkId] doesn't exist.
  Future<void> update(
    String uid,
    String bookmarkId, {
    String? title,
    String? url,
  }) async {
    final data = <String, dynamic>{
      if (title != null) 'title': title,
      if (url != null) 'url': url,
    };
    if (data.isEmpty) return;
    data['updatedAt'] = FieldValue.serverTimestamp();
    await _bookmarksFor(uid).doc(bookmarkId).update(data);
  }

  /// Records that the user just opened/revisited [bookmarkId], stamping
  /// `lastCheckedAt` server-side. (Update.) Scoped to [uid] by the subcollection
  /// path; throws if the document is missing, so callers treat it as best-effort.
  Future<void> touchLastChecked(String uid, String bookmarkId) async {
    await _bookmarksFor(uid).doc(bookmarkId).update(<String, dynamic>{
      'lastCheckedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Deletes [bookmarkId]. (Delete.) Scoped to [uid] by the subcollection path;
  /// a no-op when the document is already gone (Firestore deletes are
  /// idempotent). The live [watchForUser] stream then drops it from the list.
  Future<void> delete(String uid, String bookmarkId) async {
    await _bookmarksFor(uid).doc(bookmarkId).delete();
  }
}
