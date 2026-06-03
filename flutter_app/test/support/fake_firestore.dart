// A tiny in-memory fake of the slice of the `cloud_firestore` API the
// repositories actually use.
//
// The project can't pull `fake_cloud_firestore` from pub (the deploy/test host
// sits behind a TLS-terminating proxy), and the existing tests already hand-roll
// fakes via `noSuchMethod`, so this follows the same convention: it implements
// only the handful of methods `NotificationRepository` and `BookmarkRepository`
// call and routes everything else to `noSuchMethod` (which throws), keeping the
// surface honest — a repository reaching for an unfaked method fails loudly
// rather than silently no-opping.
//
// Documents live in a single `Map<path, data>` store keyed by full document
// path (e.g. `notifications/abc`, `users/u1/bookmarks/b1`). Collection queries
// match documents that sit directly under the collection path, apply `isEqualTo`
// filters and an optional `orderBy`/`limit`, exactly like the real client for
// the equality+order queries these repositories issue. `FieldValue` sentinels
// (e.g. `serverTimestamp()`) are stored verbatim so a test can assert that a
// write *requested* a server stamp.
//
// The `cloud_firestore` interfaces are `@sealed` (a package:meta hint, not a
// language `sealed` — so implementing them still compiles), but faking them is
// exactly the point here; the lint is silenced file-wide.
// ignore_for_file: subtype_of_sealed_class, annotate_overrides, use_super_parameters
import 'package:cloud_firestore/cloud_firestore.dart';

/// Backing store + factory for the fake document tree.
class FakeFirestore implements FirebaseFirestore {
  /// doc path -> field map. Visible to tests for seeding and assertions.
  final Map<String, Map<String, dynamic>> store = {};

  int _autoId = 0;

  /// Seeds a document at [path] with [data], creating parents implicitly (the
  /// store is path-keyed, so no parent document is required).
  void seed(String path, Map<String, dynamic> data) {
    store[path] = Map<String, dynamic>.from(data);
  }

  String nextId() => 'auto-${_autoId++}';

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) =>
      _FakeCollection(this, collectionPath);

  @override
  WriteBatch batch() => _FakeWriteBatch(this);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeFirestore.${invocation.memberName} is not faked',
  );
}

/// A single `isEqualTo` filter captured from a `where(...)` call.
class _EqFilter {
  const _EqFilter(this.field, this.value);
  final Object field;
  final Object? value;
}

class _FakeQuery implements Query<Map<String, dynamic>> {
  _FakeQuery(
    this._fs,
    this._collectionPath, {
    List<_EqFilter> filters = const [],
    String? orderByField,
    bool descending = false,
    int? limit,
    String? startAfterId,
  }) : _filters = filters,
       _orderByField = orderByField,
       _descending = descending,
       _limit = limit,
       _startAfterId = startAfterId;

  final FakeFirestore _fs;
  final String _collectionPath;
  final List<_EqFilter> _filters;
  final String? _orderByField;
  final bool _descending;
  final int? _limit;

  /// Id of the document the cursor sits after (set via [startAfterDocument]);
  /// `null` means no cursor.
  final String? _startAfterId;

  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) {
    if (isEqualTo == null) {
      throw UnimplementedError('FakeFirestore only fakes where(isEqualTo:)');
    }
    return _copyWith(filters: [..._filters, _EqFilter(field, isEqualTo)]);
  }

  @override
  Query<Map<String, dynamic>> orderBy(
    Object field, {
    bool descending = false,
  }) => _copyWith(orderByField: field as String, descending: descending);

  @override
  Query<Map<String, dynamic>> limit(int limit) => _copyWith(limit: limit);

  @override
  Query<Map<String, dynamic>> startAfterDocument(
    DocumentSnapshot<Object?> documentSnapshot,
  ) => _copyWith(startAfterId: documentSnapshot.id);

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async => _FakeQuerySnapshot(_matching());

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => Stream.value(_FakeQuerySnapshot(_matching()));

  _FakeQuery _copyWith({
    List<_EqFilter>? filters,
    String? orderByField,
    bool? descending,
    int? limit,
    String? startAfterId,
  }) => _FakeQuery(
    _fs,
    _collectionPath,
    filters: filters ?? _filters,
    orderByField: orderByField ?? _orderByField,
    descending: descending ?? _descending,
    limit: limit ?? _limit,
    startAfterId: startAfterId ?? _startAfterId,
  );

  /// Documents directly under [_collectionPath], filtered, ordered and capped.
  List<_FakeQueryDocSnapshot> _matching() {
    final prefix = '$_collectionPath/';
    var entries = _fs.store.entries
        .where((e) {
          if (!e.key.startsWith(prefix)) return false;
          final rest = e.key.substring(prefix.length);
          return !rest.contains(
            '/',
          ); // direct child, not a sub-subcollection doc
        })
        .where((e) => _filters.every((f) => e.value[f.field] == f.value))
        .toList();

    final orderField = _orderByField;
    if (orderField != null) {
      entries.sort((a, b) {
        final cmp = _compare(a.value[orderField], b.value[orderField]);
        return _descending ? -cmp : cmp;
      });
    }

    var docs = entries
        .map((e) => _FakeQueryDocSnapshot(_fs, e.key, _idOf(e.key), e.value))
        .toList();

    // Cursor: drop everything up to and including the start-after document,
    // matched by id within the already-ordered list (mirrors Firestore's
    // startAfterDocument positioning for these single-orderBy queries).
    final after = _startAfterId;
    if (after != null) {
      final at = docs.indexWhere((d) => d.id == after);
      docs = at < 0 ? <_FakeQueryDocSnapshot>[] : docs.sublist(at + 1);
    }

    final cap = _limit;
    if (cap != null && docs.length > cap) docs = docs.sublist(0, cap);
    return docs;
  }

  static int _compare(Object? a, Object? b) {
    if (a is Timestamp && b is Timestamp) return a.compareTo(b);
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    if (a is Comparable) return a.compareTo(b);
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeQuery.${invocation.memberName} is not faked',
  );
}

class _FakeCollection extends _FakeQuery
    implements CollectionReference<Map<String, dynamic>> {
  _FakeCollection(FakeFirestore fs, String path) : super(fs, path);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _FakeDocRef(_fs, '$_collectionPath/${path ?? _fs.nextId()}');

  @override
  Future<DocumentReference<Map<String, dynamic>>> add(
    Map<String, dynamic> data,
  ) async {
    final ref = _FakeDocRef(_fs, '$_collectionPath/${_fs.nextId()}');
    _fs.store[ref.path] = Map<String, dynamic>.from(data);
    return ref;
  }
}

class _FakeDocRef implements DocumentReference<Map<String, dynamic>> {
  _FakeDocRef(this._fs, this.path);

  final FakeFirestore _fs;
  final String path;

  @override
  String get id => _idOf(path);

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) =>
      _FakeCollection(_fs, '$path/$collectionPath');

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async => _FakeDocSnapshot(_fs, path, _fs.store[path]);

  @override
  Future<void> update(Map<Object, Object?> data) async {
    final existing = _fs.store[path];
    if (existing == null) {
      throw StateError('update on missing document: $path');
    }
    data.forEach((k, v) => existing['$k'] = v);
  }

  @override
  Future<void> delete() async {
    _fs.store.remove(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeDocRef.${invocation.memberName} is not faked',
  );
}

class _FakeDocSnapshot implements DocumentSnapshot<Map<String, dynamic>> {
  _FakeDocSnapshot(this._fs, this.path, this._data);

  final FakeFirestore _fs;
  final String path;
  final Map<String, dynamic>? _data;

  @override
  String get id => _idOf(path);

  @override
  bool get exists => _data != null;

  @override
  Map<String, dynamic>? data() =>
      _data == null ? null : Map<String, dynamic>.from(_data);

  @override
  DocumentReference<Map<String, dynamic>> get reference =>
      _FakeDocRef(_fs, path);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeDocSnapshot.${invocation.memberName} is not faked',
  );
}

class _FakeQueryDocSnapshot
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _FakeQueryDocSnapshot(this._fs, this.path, this._id, this._data);

  final FakeFirestore _fs;
  final String path;
  final String _id;
  final Map<String, dynamic> _data;

  @override
  String get id => _id;

  @override
  bool get exists => true;

  @override
  Map<String, dynamic> data() => Map<String, dynamic>.from(_data);

  @override
  DocumentReference<Map<String, dynamic>> get reference =>
      _FakeDocRef(_fs, path);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeQueryDocSnapshot.${invocation.memberName} is not faked',
  );
}

class _FakeQuerySnapshot implements QuerySnapshot<Map<String, dynamic>> {
  _FakeQuerySnapshot(this._docs);

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs;

  @override
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get docs => _docs;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeQuerySnapshot.${invocation.memberName} is not faked',
  );
}

class _FakeWriteBatch implements WriteBatch {
  _FakeWriteBatch(this._fs);

  final FakeFirestore _fs;
  final List<void Function()> _ops = [];

  @override
  void update(DocumentReference document, Map<String, dynamic> data) {
    final ref = document as _FakeDocRef;
    _ops.add(() {
      final existing = _fs.store[ref.path];
      if (existing != null) data.forEach((k, v) => existing[k] = v);
    });
  }

  @override
  Future<void> commit() async {
    for (final op in _ops) {
      op();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeWriteBatch.${invocation.memberName} is not faked',
  );
}

String _idOf(String path) => path.substring(path.lastIndexOf('/') + 1);
