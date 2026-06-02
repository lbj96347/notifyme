import 'bookmark.dart';

/// A run of bookmarks that share a calendar day, with a human label for the
/// section header ("Today", "Yesterday", or e.g. "May 28, 2026").
///
/// Grouping lives here — UI-free and testable — so the bookmarks screen only has
/// to render the result, exactly as the inbox groups its notifications.
/// Bookmarks without a resolved [Bookmark.createdAt] (a freshly-saved
/// `serverTimestamp()` that hasn't landed yet) are collected under a "Pending"
/// group so they still appear at the top of the newest-first list instead of
/// vanishing.
class BookmarkDayGroup {
  const BookmarkDayGroup({required this.label, required this.bookmarks});

  final String label;
  final List<Bookmark> bookmarks;

  /// Splits a newest-first list into day groups, preserving order.
  ///
  /// [now] is injectable so "Today" / "Yesterday" can be tested
  /// deterministically; it defaults to the current time.
  static List<BookmarkDayGroup> groupByDay(
    List<Bookmark> bookmarks, {
    DateTime? now,
  }) {
    final today = _dateOnly(now ?? DateTime.now());
    final yesterday = today.subtract(const Duration(days: 1));

    final groups = <BookmarkDayGroup>[];
    var current = <Bookmark>[];
    String? currentLabel;

    void flush() {
      if (currentLabel != null && current.isNotEmpty) {
        groups.add(BookmarkDayGroup(label: currentLabel, bookmarks: current));
      }
    }

    for (final b in bookmarks) {
      final created = b.createdAt;
      final String label;
      if (created == null) {
        label = 'Pending';
      } else {
        final day = _dateOnly(created.toLocal());
        if (day == today) {
          label = 'Today';
        } else if (day == yesterday) {
          label = 'Yesterday';
        } else {
          label = formatDate(day, now: now);
        }
      }

      if (label != currentLabel) {
        flush();
        current = <Bookmark>[];
        currentLabel = label;
      }
      current.add(b);
    }
    flush();

    return groups;
  }

  static DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  static const List<String> _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// "May 28, 2026" — drops the year when it's the current year.
  static String formatDate(DateTime day, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final month = _months[day.month - 1];
    if (day.year == reference.year) {
      return '$month ${day.day}';
    }
    return '$month ${day.day}, ${day.year}';
  }

  /// "14:30" in the device's local time.
  static String formatTime(DateTime dt) {
    final local = dt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// A compact absolute stamp for a moment that has no day header of its own
  /// (e.g. a row's `lastCheckedAt`): just the time when it's today, otherwise
  /// the date and time. [now] is injectable for deterministic tests.
  static String formatStamp(DateTime dt, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final local = dt.toLocal();
    final day = _dateOnly(local);
    if (day == _dateOnly(reference)) {
      return formatTime(local);
    }
    return '${formatDate(day, now: reference)} at ${formatTime(local)}';
  }
}
