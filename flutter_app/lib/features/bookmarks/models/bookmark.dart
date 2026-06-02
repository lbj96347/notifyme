import 'package:cloud_firestore/cloud_firestore.dart';

/// An immutable saved link the user wants to keep and revisit.
///
/// A bookmark is its own `bookmarks/{id}` document (scoped to the owner's
/// `uid`), not a view onto a notification: it stores the link itself (`title`,
/// `url`) plus the lifecycle timestamps the app needs — `createdAt` (when it was
/// saved), `updatedAt` (when its fields last changed), and `lastCheckedAt` (when
/// the user last opened/revisited it). The boolean "is bookmarked" flag from the
/// old notification-star model is gone; a row's existence in the collection *is*
/// the bookmark.
///
/// Parsing is tolerant: missing or wrong-typed fields fall back to sensible
/// defaults so a malformed document never crashes the list. Serialization
/// (`toMap`) round-trips the same shape so a `Bookmark` written here re-parses to
/// an equal value.
class Bookmark {
  const Bookmark({
    required this.id,
    required this.uid,
    required this.title,
    required this.url,
    this.createdAt,
    this.updatedAt,
    this.lastCheckedAt,
  });

  /// The Firestore document id. Not part of the serialized map — it's the key,
  /// not a field.
  final String id;

  /// Owner uid; every read/write is scoped to it, mirroring the security rules.
  final String uid;

  /// Human label for the saved link.
  final String title;

  /// The saved link. Tapping a bookmark opens this.
  final String url;

  /// Server timestamp the bookmark was first saved. May be `null` briefly while
  /// a freshly written document's `serverTimestamp()` resolves.
  final DateTime? createdAt;

  /// Server timestamp the bookmark's fields were last edited.
  final DateTime? updatedAt;

  /// Server timestamp the user last opened/revisited the link.
  final DateTime? lastCheckedAt;

  /// Builds a bookmark from a Firestore document snapshot.
  factory Bookmark.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> doc) {
    return Bookmark.fromMap(doc.id, doc.data() ?? const <String, dynamic>{});
  }

  /// Builds a bookmark from a document [id] and its raw [data] map.
  ///
  /// Tolerant of missing/mistyped fields; timestamps that haven't resolved (or
  /// aren't `Timestamp`s) parse to `null`.
  factory Bookmark.fromMap(String id, Map<String, dynamic> data) {
    return Bookmark(
      id: id,
      uid: _toString(data['uid']),
      title: _toString(data['title']),
      url: _toString(data['url']),
      createdAt: _toDate(data['createdAt']),
      updatedAt: _toDate(data['updatedAt']),
      lastCheckedAt: _toDate(data['lastCheckedAt']),
    );
  }

  /// Serializes to a Firestore-writable map.
  ///
  /// Excludes [id] (the document key). Timestamps are written as Firestore
  /// [Timestamp]s when set and omitted when `null`, so callers that want the
  /// server to stamp a field can merge in a `FieldValue.serverTimestamp()`
  /// without this map overwriting it with `null`.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'uid': uid,
      'title': title,
      'url': url,
      if (createdAt != null) 'createdAt': Timestamp.fromDate(createdAt!),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      if (lastCheckedAt != null)
        'lastCheckedAt': Timestamp.fromDate(lastCheckedAt!),
    };
  }

  /// Returns a copy with the given fields replaced.
  Bookmark copyWith({
    String? id,
    String? uid,
    String? title,
    String? url,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastCheckedAt,
  }) {
    return Bookmark(
      id: id ?? this.id,
      uid: uid ?? this.uid,
      title: title ?? this.title,
      url: url ?? this.url,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    );
  }

  static DateTime? _toDate(Object? value) =>
      value is Timestamp ? value.toDate() : null;

  /// Coerces a raw field to a [String], defaulting to `''` for missing or
  /// wrong-typed values so a malformed document never crashes parsing.
  static String _toString(Object? value) => value is String ? value : '';
}
