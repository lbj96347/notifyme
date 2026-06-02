// Unit tests for the bookmark model: tolerant parsing, serialization
// round-trip, copyWith, and the day-grouping/formatting helpers.
//
// These are pure (no Firebase init): `Timestamp` is a plain value type, so the
// model and grouping logic can be exercised directly.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/features/bookmarks/models/bookmark.dart';
import 'package:notifyme/features/bookmarks/models/bookmark_day_group.dart';

void main() {
  group('Bookmark.fromMap', () {
    test('parses a fully-populated document', () {
      final created = DateTime(2026, 5, 28, 14, 30);
      final updated = DateTime(2026, 5, 29, 9, 0);
      final checked = DateTime(2026, 5, 30, 18, 45);
      final b = Bookmark.fromMap('id-1', {
        'uid': 'u1',
        'title': 'Flutter docs',
        'url': 'https://flutter.dev',
        'createdAt': Timestamp.fromDate(created),
        'updatedAt': Timestamp.fromDate(updated),
        'lastCheckedAt': Timestamp.fromDate(checked),
      });

      expect(b.id, 'id-1');
      expect(b.uid, 'u1');
      expect(b.title, 'Flutter docs');
      expect(b.url, 'https://flutter.dev');
      expect(b.createdAt, created);
      expect(b.updatedAt, updated);
      expect(b.lastCheckedAt, checked);
    });

    test('falls back to defaults for missing fields', () {
      final b = Bookmark.fromMap('id-2', const {});
      expect(b.id, 'id-2');
      expect(b.uid, '');
      expect(b.title, '');
      expect(b.url, '');
      expect(b.createdAt, isNull);
      expect(b.updatedAt, isNull);
      expect(b.lastCheckedAt, isNull);
    });

    test('tolerates wrong-typed fields without throwing', () {
      final b = Bookmark.fromMap('id-3', const {
        'uid': 42,
        'title': true,
        'url': ['not', 'a', 'string'],
        'createdAt': 'not-a-timestamp',
      });
      expect(b.uid, '');
      expect(b.title, '');
      expect(b.url, '');
      expect(b.createdAt, isNull);
    });

    test('leaves unresolved (non-Timestamp) timestamps as null', () {
      // A freshly written serverTimestamp() that hasn't landed reads back as a
      // value the client can't coerce; it must parse to null, not crash.
      final b = Bookmark.fromMap('id-4', const {'uid': 'u1', 'createdAt': 0});
      expect(b.createdAt, isNull);
    });
  });

  group('Bookmark.toMap', () {
    test('omits unset timestamps and never writes id', () {
      const b = Bookmark(id: 'id-1', uid: 'u1', title: 't', url: 'https://x.y');
      final map = b.toMap();
      expect(map.containsKey('id'), isFalse);
      expect(map['uid'], 'u1');
      expect(map['title'], 't');
      expect(map['url'], 'https://x.y');
      expect(map.containsKey('createdAt'), isFalse);
      expect(map.containsKey('updatedAt'), isFalse);
      expect(map.containsKey('lastCheckedAt'), isFalse);
    });

    test('writes set timestamps as Firestore Timestamps', () {
      final created = DateTime(2026, 5, 28, 14, 30);
      final b = Bookmark(
        id: 'id-1',
        uid: 'u1',
        title: 't',
        url: 'https://x.y',
        createdAt: created,
      );
      final map = b.toMap();
      expect(map['createdAt'], isA<Timestamp>());
      expect((map['createdAt'] as Timestamp).toDate(), created);
    });

    test('round-trips through fromMap to an equal value', () {
      final original = Bookmark(
        id: 'id-7',
        uid: 'u1',
        title: 'Round trip',
        url: 'https://example.com/path',
        createdAt: DateTime(2026, 5, 28, 14, 30),
        updatedAt: DateTime(2026, 5, 29),
        lastCheckedAt: DateTime(2026, 5, 30),
      );
      final restored = Bookmark.fromMap('id-7', original.toMap());

      expect(restored.id, original.id);
      expect(restored.uid, original.uid);
      expect(restored.title, original.title);
      expect(restored.url, original.url);
      expect(restored.createdAt, original.createdAt);
      expect(restored.updatedAt, original.updatedAt);
      expect(restored.lastCheckedAt, original.lastCheckedAt);
    });
  });

  group('Bookmark.copyWith', () {
    const base = Bookmark(
      id: 'id',
      uid: 'u1',
      title: 'old',
      url: 'https://a.b',
    );

    test('replaces only the given fields', () {
      final updated = base.copyWith(title: 'new', url: 'https://c.d');
      expect(updated.id, 'id');
      expect(updated.uid, 'u1');
      expect(updated.title, 'new');
      expect(updated.url, 'https://c.d');
    });

    test('preserves fields that are not passed', () {
      final updated = base.copyWith(title: 'new');
      expect(updated.url, base.url);
      expect(updated.uid, base.uid);
    });
  });

  group('BookmarkDayGroup.groupByDay', () {
    Bookmark at(DateTime? created, {String id = 'x'}) => Bookmark(
      id: id,
      uid: 'u1',
      title: id,
      url: 'https://x.y',
      createdAt: created,
    );

    final now = DateTime(2026, 6, 1, 12, 0); // a fixed "today" for determinism

    test('labels today, yesterday, and older dates; preserves order', () {
      final groups = BookmarkDayGroup.groupByDay([
        at(DateTime(2026, 6, 1, 9, 0), id: 'a'), // today
        at(DateTime(2026, 6, 1, 8, 0), id: 'b'), // today
        at(DateTime(2026, 5, 31, 22, 0), id: 'c'), // yesterday
        at(DateTime(2026, 5, 28, 10, 0), id: 'd'), // older, same year
      ], now: now);

      expect(groups.map((g) => g.label).toList(), [
        'Today',
        'Yesterday',
        'May 28',
      ]);
      expect(groups[0].bookmarks.map((b) => b.id).toList(), ['a', 'b']);
      expect(groups[1].bookmarks.single.id, 'c');
      expect(groups[2].bookmarks.single.id, 'd');
    });

    test('collects unresolved timestamps under a Pending group', () {
      final groups = BookmarkDayGroup.groupByDay([
        at(null, id: 'p1'),
        at(null, id: 'p2'),
        at(DateTime(2026, 6, 1, 9, 0), id: 'today'),
      ], now: now);
      expect(groups.first.label, 'Pending');
      expect(groups.first.bookmarks.map((b) => b.id).toList(), ['p1', 'p2']);
      expect(groups[1].label, 'Today');
    });

    test('returns no groups for an empty list', () {
      expect(BookmarkDayGroup.groupByDay(const [], now: now), isEmpty);
    });
  });

  group('BookmarkDayGroup formatting', () {
    final now = DateTime(2026, 6, 1, 12, 0);

    test('formatDate drops the year in the current year', () {
      expect(
        BookmarkDayGroup.formatDate(DateTime(2026, 5, 28), now: now),
        'May 28',
      );
    });

    test('formatDate keeps the year for other years', () {
      expect(
        BookmarkDayGroup.formatDate(DateTime(2025, 12, 25), now: now),
        'December 25, 2025',
      );
    });

    test('formatTime zero-pads hours and minutes', () {
      expect(BookmarkDayGroup.formatTime(DateTime(2026, 6, 1, 9, 5)), '09:05');
    });

    test('formatStamp shows time only for today, date+time otherwise', () {
      expect(
        BookmarkDayGroup.formatStamp(DateTime(2026, 6, 1, 14, 30), now: now),
        '14:30',
      );
      expect(
        BookmarkDayGroup.formatStamp(DateTime(2026, 5, 28, 14, 30), now: now),
        'May 28 at 14:30',
      );
    });
  });
}
