// Behavior tests for [BookmarkRepository] against an in-memory fake Firestore
// (see test/support/fake_firestore.dart). They pin: structural ownership (writes
// land under users/{uid}/bookmarks), server-stamped timestamps on create/update,
// field-preserving edits, the empty-update no-op, idempotent delete, and the
// newest-first scoped stream.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/features/bookmarks/repository/bookmark_repository.dart';

import 'support/fake_firestore.dart';

void main() {
  late FakeFirestore fs;
  late BookmarkRepository repo;

  setUp(() {
    fs = FakeFirestore();
    repo = BookmarkRepository(firestore: fs);
  });

  String pathFor(String uid, String id) => 'users/$uid/bookmarks/$id';

  group('add', () {
    test(
      'writes under users/{uid}/bookmarks with server-stamped times',
      () async {
        final id = await repo.add(
          'u1',
          title: 'Docs',
          url: 'https://flutter.dev',
        );

        final stored = fs.store[pathFor('u1', id)];
        expect(stored, isNotNull);
        expect(stored!['uid'], 'u1');
        expect(stored['title'], 'Docs');
        expect(stored['url'], 'https://flutter.dev');
        // createdAt/updatedAt are left for the server to stamp.
        expect(stored['createdAt'], isA<FieldValue>());
        expect(stored['updatedAt'], isA<FieldValue>());
      },
    );
  });

  group('fetchById', () {
    test('returns null when the bookmark does not exist', () async {
      expect(await repo.fetchById('u1', 'missing'), isNull);
    });

    test('parses an existing bookmark', () async {
      final created = DateTime(2026, 5, 28, 14, 30);
      fs.seed(pathFor('u1', 'b1'), {
        'uid': 'u1',
        'title': 'Saved',
        'url': 'https://example.com',
        'createdAt': Timestamp.fromDate(created),
      });

      final b = await repo.fetchById('u1', 'b1');
      expect(b, isNotNull);
      expect(b!.id, 'b1');
      expect(b.title, 'Saved');
      expect(b.url, 'https://example.com');
      expect(b.createdAt, created);
    });
  });

  group('update', () {
    test(
      'edits the given fields and stamps updatedAt, preserving others',
      () async {
        final created = DateTime(2026, 5, 28);
        final checked = DateTime(2026, 5, 29);
        fs.seed(pathFor('u1', 'b1'), {
          'uid': 'u1',
          'title': 'old',
          'url': 'https://old.example',
          'createdAt': Timestamp.fromDate(created),
          'lastCheckedAt': Timestamp.fromDate(checked),
        });

        await repo.update('u1', 'b1', title: 'new', url: 'https://new.example');

        final stored = fs.store[pathFor('u1', 'b1')]!;
        expect(stored['title'], 'new');
        expect(stored['url'], 'https://new.example');
        expect(stored['updatedAt'], isA<FieldValue>());
        // createdAt and lastCheckedAt are left intact.
        expect((stored['createdAt'] as Timestamp).toDate(), created);
        expect((stored['lastCheckedAt'] as Timestamp).toDate(), checked);
      },
    );

    test('is a no-op (no write) when neither field is supplied', () async {
      fs.seed(pathFor('u1', 'b1'), {'uid': 'u1', 'title': 't', 'url': 'u'});
      await repo.update('u1', 'b1');
      expect(fs.store[pathFor('u1', 'b1')]!.containsKey('updatedAt'), isFalse);
    });

    test('throws when the bookmark does not exist', () async {
      expect(
        () => repo.update('u1', 'ghost', title: 'x'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('touchLastChecked', () {
    test('stamps lastCheckedAt server-side', () async {
      fs.seed(pathFor('u1', 'b1'), {'uid': 'u1', 'title': 't', 'url': 'u'});
      await repo.touchLastChecked('u1', 'b1');
      expect(
        fs.store[pathFor('u1', 'b1')]!['lastCheckedAt'],
        isA<FieldValue>(),
      );
    });
  });

  group('delete', () {
    test('removes the bookmark', () async {
      fs.seed(pathFor('u1', 'b1'), {'uid': 'u1', 'title': 't', 'url': 'u'});
      await repo.delete('u1', 'b1');
      expect(fs.store.containsKey(pathFor('u1', 'b1')), isFalse);
    });

    test('is idempotent when the bookmark is already gone', () async {
      await repo.delete('u1', 'gone'); // must not throw
      expect(fs.store.containsKey(pathFor('u1', 'gone')), isFalse);
    });
  });

  group('watchForUser', () {
    test(
      'emits the user\'s bookmarks newest-first and is scoped by uid',
      () async {
        fs.seed(pathFor('u1', 'old'), {
          'uid': 'u1',
          'createdAt': Timestamp.fromDate(DateTime(2026, 5, 1)),
        });
        fs.seed(pathFor('u1', 'new'), {
          'uid': 'u1',
          'createdAt': Timestamp.fromDate(DateTime(2026, 5, 30)),
        });
        // Another user's bookmark must never appear in u1's stream.
        fs.seed(pathFor('u2', 'other'), {
          'uid': 'u2',
          'createdAt': Timestamp.fromDate(DateTime(2026, 5, 31)),
        });

        final list = await repo.watchForUser('u1').first;
        expect(list.map((b) => b.id).toList(), ['new', 'old']);
      },
    );

    test('applies the limit', () async {
      for (var i = 0; i < 5; i++) {
        fs.seed(pathFor('u1', 'b$i'), {
          'uid': 'u1',
          'createdAt': Timestamp.fromDate(DateTime(2026, 5, i + 1)),
        });
      }
      final list = await repo.watchForUser('u1', limit: 3).first;
      expect(list.length, 3);
    });
  });
}
