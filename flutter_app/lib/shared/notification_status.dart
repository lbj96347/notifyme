import 'package:flutter/material.dart';

import 'retro_palette.dart';

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
  /// yellow=warning, blue=info. Retro-toned via [RetroPalette] so the inbox
  /// stays in the app icon's world.
  Color get color {
    switch (this) {
      case NotificationStatus.success:
        return RetroPalette.statusSuccess;
      case NotificationStatus.error:
        return RetroPalette.statusError;
      case NotificationStatus.warning:
        return RetroPalette.statusWarning;
      case NotificationStatus.info:
        return RetroPalette.statusInfo;
    }
  }
}
