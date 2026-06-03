// Widget tests for [NotificationGroupedList]'s trailing footer states.
//
// The list appends at most one footer — a load-more spinner, a load-more error
// with a retry button, or an end-of-list marker — driven by the inbox
// controller's pagination state. These tests pump the list directly with a
// fixed set of rows so each footer can be asserted in isolation, including the
// error → retry callback wiring.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/features/notifications/notification_date_group.dart';
import 'package:notifyme/features/notifications/notification_list.dart';
import 'package:notifyme/features/notifications/notification_model.dart';
import 'package:notifyme/features/notifications/notification_repository.dart';

import 'support/fake_firestore.dart';

void main() {
  late NotificationRepository repo;

  setUp(() {
    repo = NotificationRepository(firestore: FakeFirestore());
  });

  // One row is enough; the footer is independent of how many rows precede it.
  List<NotificationDateGroup> oneRow() {
    final n = AppNotification(
      id: 'n0',
      uid: 'me',
      title: 'Title n0',
      message: 'Message n0',
      category: 'claude',
      status: 'success',
      read: false,
      createdAt: DateTime(2026, 5, 1, 0, 0),
    );
    return NotificationDateGroup.groupByDay([n], now: DateTime(2026, 5, 1));
  }

  Future<void> pump(
    WidgetTester tester, {
    bool isLoadingMore = false,
    bool loadMoreError = false,
    VoidCallback? onRetryLoadMore,
    bool hasReachedEnd = false,
    bool canLoadMoreForSearch = false,
    VoidCallback? onLoadMore,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationGroupedList(
            groups: oneRow(),
            uid: 'me',
            repository: repo,
            isLoadingMore: isLoadingMore,
            loadMoreError: loadMoreError,
            onRetryLoadMore: onRetryLoadMore,
            hasReachedEnd: hasReachedEnd,
            canLoadMoreForSearch: canLoadMoreForSearch,
            onLoadMore: onLoadMore,
          ),
        ),
      ),
    );
  }

  testWidgets('shows a spinner footer while loading more', (tester) async {
    await pump(tester, isLoadingMore: true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Couldn’t load more.'), findsNothing);
    expect(find.text('You’re all caught up'), findsNothing);
  });

  testWidgets('shows an end-of-list footer when there is nothing more', (
    tester,
  ) async {
    await pump(tester, hasReachedEnd: true);

    expect(find.text('You’re all caught up'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows a retry footer on a load-more error and fires onRetry', (
    tester,
  ) async {
    var retries = 0;
    await pump(
      tester,
      loadMoreError: true,
      onRetryLoadMore: () => retries++,
    );

    expect(find.text('Couldn’t load more.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('the error footer takes precedence over the spinner', (
    tester,
  ) async {
    await pump(tester, isLoadingMore: true, loadMoreError: true);

    expect(find.text('Couldn’t load more.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('no footer is shown when idle with more to load', (tester) async {
    await pump(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Couldn’t load more.'), findsNothing);
    expect(find.text('You’re all caught up'), findsNothing);
  });

  testWidgets('shows a search load-more footer and fires onLoadMore', (
    tester,
  ) async {
    var loads = 0;
    await pump(
      tester,
      canLoadMoreForSearch: true,
      onLoadMore: () => loads++,
    );

    expect(find.text('Searching loaded notifications only.'), findsOneWidget);
    expect(find.text('Load more results'), findsOneWidget);
    // The end marker is never shown alongside the search load-more prompt.
    expect(find.text('You’re all caught up'), findsNothing);

    await tester.tap(find.text('Load more results'));
    await tester.pump();
    expect(loads, 1);
  });

  testWidgets('a load in flight takes precedence over the search footer', (
    tester,
  ) async {
    await pump(tester, isLoadingMore: true, canLoadMoreForSearch: true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Load more results'), findsNothing);
  });

  testWidgets('the search footer takes precedence over the end marker', (
    tester,
  ) async {
    await pump(tester, canLoadMoreForSearch: true, hasReachedEnd: true);

    expect(find.text('Load more results'), findsOneWidget);
    expect(find.text('You’re all caught up'), findsNothing);
  });
}
