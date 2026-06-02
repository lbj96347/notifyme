// Behavior tests for [NotificationRepository] against an in-memory fake
// Firestore (see test/support/fake_firestore.dart). They pin the parts that
// carry real logic: the uid ownership guards, the already-in-state no-ops, the
// query ordering/limit, and the batched mark-all-read.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/features/notifications/notification_repository.dart';

import 'support/fake_firestore.dart';

void main() {
  late FakeFirestore fs;
  late NotificationRepository repo;

  setUp(() {
    fs = FakeFirestore();
    repo = NotificationRepository(firestore: fs);
  });

  Map<String, dynamic> note({
    String uid = 'me',
    bool read = false,
    bool bookmarked = false,
    DateTime? createdAt,
  }) => {
    'uid': uid,
    'title': 't',
    'message': 'm',
    'read': read,
    'bookmarked': bookmarked,
    if (createdAt != null) 'createdAt': Timestamp.fromDate(createdAt),
  };

  group('fetchById', () {
    test('returns the notification when it belongs to the user', () async {
      fs.seed('notifications/n1', note(uid: 'me'));
      final result = await repo.fetchById('me', 'n1');
      expect(result, isNotNull);
      expect(result!.id, 'n1');
      expect(result.uid, 'me');
    });

    test('returns null when the document belongs to another user', () async {
      fs.seed('notifications/n1', note(uid: 'someone-else'));
      expect(await repo.fetchById('me', 'n1'), isNull);
    });

    test('returns null when the document is missing', () async {
      expect(await repo.fetchById('me', 'nope'), isNull);
    });
  });

  group('markRead', () {
    test('flips an unread notification to read', () async {
      fs.seed('notifications/n1', note(read: false));
      await repo.markRead('me', 'n1');
      expect(fs.store['notifications/n1']!['read'], isTrue);
    });

    test('is a no-op for a notification owned by someone else', () async {
      fs.seed('notifications/n1', note(uid: 'other', read: false));
      await repo.markRead('me', 'n1');
      expect(fs.store['notifications/n1']!['read'], isFalse);
    });

    test('is a no-op when already read', () async {
      fs.seed('notifications/n1', note(read: true));
      await repo.markRead('me', 'n1'); // must not throw
      expect(fs.store['notifications/n1']!['read'], isTrue);
    });

    test('is a no-op when the document is missing', () async {
      await repo.markRead('me', 'ghost'); // must not throw
      expect(fs.store.containsKey('notifications/ghost'), isFalse);
    });
  });

  group('setBookmark', () {
    test('sets the bookmark flag on an own notification', () async {
      fs.seed('notifications/n1', note(bookmarked: false));
      await repo.setBookmark('me', 'n1', bookmarked: true);
      expect(fs.store['notifications/n1']!['bookmarked'], isTrue);
    });

    test('clears the bookmark flag', () async {
      fs.seed('notifications/n1', note(bookmarked: true));
      await repo.setBookmark('me', 'n1', bookmarked: false);
      expect(fs.store['notifications/n1']!['bookmarked'], isFalse);
    });

    test('is a no-op when already in the requested state', () async {
      fs.seed('notifications/n1', note(bookmarked: true));
      await repo.setBookmark('me', 'n1', bookmarked: true);
      expect(fs.store['notifications/n1']!['bookmarked'], isTrue);
    });

    test("is a no-op for another user's notification", () async {
      fs.seed('notifications/n1', note(uid: 'other', bookmarked: false));
      await repo.setBookmark('me', 'n1', bookmarked: true);
      expect(fs.store['notifications/n1']!['bookmarked'], isFalse);
    });
  });

  group('markAllRead', () {
    test(
      'marks only the user\'s unread notifications and returns the count',
      () async {
        fs.seed('notifications/a', note(uid: 'me', read: false));
        fs.seed('notifications/b', note(uid: 'me', read: false));
        fs.seed('notifications/c', note(uid: 'me', read: true));
        fs.seed('notifications/d', note(uid: 'other', read: false));

        final count = await repo.markAllRead('me');

        expect(count, 2);
        expect(fs.store['notifications/a']!['read'], isTrue);
        expect(fs.store['notifications/b']!['read'], isTrue);
        expect(fs.store['notifications/c']!['read'], isTrue);
        // The other user's notification is untouched.
        expect(fs.store['notifications/d']!['read'], isFalse);
      },
    );

    test('returns 0 when there is nothing unread', () async {
      fs.seed('notifications/a', note(read: true));
      expect(await repo.markAllRead('me'), 0);
    });

    test('commits in multiple batches beyond the 500-op limit', () async {
      for (var i = 0; i < 501; i++) {
        fs.seed('notifications/n$i', note(uid: 'me', read: false));
      }
      final count = await repo.markAllRead('me');
      expect(count, 501);
      expect(
        List.generate(
          501,
          (i) => fs.store['notifications/n$i']!['read'],
        ).every((r) => r == true),
        isTrue,
      );
    });
  });

  group('watchForUser', () {
    test('emits the user\'s notifications newest-first', () async {
      fs.seed('notifications/old', note(createdAt: DateTime(2026, 5, 1)));
      fs.seed('notifications/new', note(createdAt: DateTime(2026, 5, 30)));
      fs.seed('notifications/mid', note(createdAt: DateTime(2026, 5, 15)));

      final list = await repo.watchForUser('me').first;
      expect(list.map((n) => n.id).toList(), ['new', 'mid', 'old']);
    });

    test('applies the limit', () async {
      for (var i = 0; i < 5; i++) {
        fs.seed('notifications/n$i', note(createdAt: DateTime(2026, 5, i + 1)));
      }
      final list = await repo.watchForUser('me', limit: 2).first;
      expect(list.length, 2);
    });
  });
}
