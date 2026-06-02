import 'package:flutter/material.dart';

import '../../auth/auth_service.dart';
import '../models/bookmark.dart';
import '../models/bookmark_day_group.dart';
import '../repository/bookmark_repository.dart';
import '../widgets/bookmark_list.dart';

/// Opens the create-bookmark dialog and, on save, writes the new bookmark for
/// [uid] via [repository]. The live stream then surfaces it in the list, so no
/// local state changes here; failures fall back to a SnackBar.
Future<void> _createBookmark(
  BuildContext context,
  BookmarkRepository repository,
  String uid,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await showDialog<({String title, String url})>(
    context: context,
    builder: (_) => const BookmarkEditDialog(),
  );
  if (result == null) return; // Cancelled.
  try {
    await repository.add(uid, title: result.title, url: result.url);
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Couldn’t save bookmark.')),
    );
  }
}

/// The Bookmarks tab: a live, newest-first list of the saved links the user has
/// kept, grouped under Today / Yesterday / older-date headers like the inbox.
///
/// Tapping a row opens the link in the in-app browser; the trailing overflow
/// menu edits or deletes the bookmark and lets the live stream reflect the
/// change in this list. The screen owns no
/// Firestore knowledge beyond asking [BookmarkRepository] for the user's
/// bookmark stream; [authService] and [repository] are injectable so the screen
/// can be exercised in tests.
class BookmarksScreen extends StatelessWidget {
  const BookmarksScreen({
    super.key,
    BookmarkRepository? repository,
    AuthService? authService,
  }) : _repository = repository,
       _authService = authService;

  final BookmarkRepository? _repository;
  final AuthService? _authService;

  @override
  Widget build(BuildContext context) {
    final repository = _repository ?? BookmarkRepository();
    final user = (_authService ?? AuthService()).currentUser;

    if (user == null) {
      return const _BookmarksScaffold(
        body: BookmarkEmptyState(
          icon: Icons.lock_outline,
          title: 'Not signed in',
          subtitle: 'Sign in to see your bookmarks.',
        ),
      );
    }

    return _BookmarksScaffold(
      floatingActionButton: Builder(
        builder: (context) => FloatingActionButton(
          onPressed: () => _createBookmark(context, repository, user.uid),
          tooltip: 'Add bookmark',
          child: const Icon(Icons.add),
        ),
      ),
      body: StreamBuilder<List<Bookmark>>(
        stream: repository.watchForUser(user.uid),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const BookmarkEmptyState(
              icon: Icons.error_outline,
              title: 'Couldn’t load bookmarks',
              subtitle: 'Check your connection and try again.',
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final bookmarks = snapshot.data ?? const <Bookmark>[];
          if (bookmarks.isEmpty) {
            return const BookmarkEmptyState(
              icon: Icons.bookmark_border,
              title: 'No bookmarks yet',
              subtitle: 'Saved links you keep will show up here.',
            );
          }

          final groups = BookmarkDayGroup.groupByDay(bookmarks);
          return BookmarkGroupedList(
            groups: groups,
            uid: user.uid,
            repository: repository,
          );
        },
      ),
    );
  }
}

/// Shared chrome so the signed-out, loading, empty, error and populated states
/// all sit under the same app bar.
class _BookmarksScaffold extends StatelessWidget {
  const _BookmarksScaffold({required this.body, this.floatingActionButton});

  final Widget body;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bookmarks')),
      body: body,
      floatingActionButton: floatingActionButton,
    );
  }
}
