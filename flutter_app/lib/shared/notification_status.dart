import 'package:flutter/material.dart';

/// Status values carried by the webhook payload's `status` field and mapped
/// to inbox colors. This enum is part of the payload contract shared across
/// the Cloud Function, this app, and the `examples/` — keep them in sync.
enum NotificationStatus {
  success,
  error,
  warning,
  info;

  /// Parses the wire value (e.g. `"success"`) from a notification document or
  /// webhook payload, defaulting to [info] for unknown/missing values.
  static NotificationStatus fromWire(String? value) {
    return NotificationStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => NotificationStatus.info,
    );
  }

  /// The inbox color for this status: green=success, red=error,
  /// yellow=warning, blue=info.
  Color get color {
    switch (this) {
      case NotificationStatus.success:
        return Colors.green;
      case NotificationStatus.error:
        return Colors.red;
      case NotificationStatus.warning:
        return Colors.amber;
      case NotificationStatus.info:
        return Colors.blue;
    }
  }
}
