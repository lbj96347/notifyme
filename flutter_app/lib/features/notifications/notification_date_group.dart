import 'notification_model.dart';

/// A run of notifications that share a calendar day, with a human label for
/// the section header ("Today", "Yesterday", or e.g. "May 28, 2026").
///
/// Grouping lives here — UI-free and testable — so the inbox widget only has
/// to render the result. Notifications without a resolved [createdAt] (a
/// freshly-written `serverTimestamp()` that hasn't landed yet) are collected
/// under a trailing "Pending" group so they still appear at the top of the
/// newest-first list instead of vanishing.
class NotificationDateGroup {
  const NotificationDateGroup({
    required this.label,
    required this.notifications,
  });

  final String label;
  final List<AppNotification> notifications;

  /// Splits a newest-first list into day groups, preserving order.
  ///
  /// [now] is injectable so "Today" / "Yesterday" can be tested deterministically;
  /// it defaults to the current time.
  static List<NotificationDateGroup> groupByDay(
    List<AppNotification> notifications, {
    DateTime? now,
  }) {
    final today = _dateOnly(now ?? DateTime.now());
    final yesterday = today.subtract(const Duration(days: 1));

    final groups = <NotificationDateGroup>[];
    var current = <AppNotification>[];
    String? currentLabel;

    void flush() {
      if (currentLabel != null && current.isNotEmpty) {
        groups.add(
          NotificationDateGroup(label: currentLabel, notifications: current),
        );
      }
    }

    for (final n in notifications) {
      final created = n.createdAt;
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
        current = <AppNotification>[];
        currentLabel = label;
      }
      current.add(n);
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
}
