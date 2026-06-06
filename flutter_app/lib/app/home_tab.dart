// Shared handle for HomePage's selected bottom-nav tab.
//
// Lives in its own file (rather than home_page.dart) so navigation that
// originates *outside* the widget tree can switch tabs without importing the
// HomePage library — and so HomePage can keep importing NotificationTapRouter
// without a circular import. A `notifyme://inbox` deep link, handled by
// NotificationTapRouter from an FCM/home-widget callback, sets [homeTabIndex] to
// bring the inbox forward even when another tab is showing.

import 'package:flutter/foundation.dart';

/// Index of the inbox tab in HomePage's bottom navigation. The inbox is the
/// default landing tab (it's where a tapped push or widget item lands).
const int homeInboxTabIndex = 0;

/// HomePage's currently-selected bottom-nav tab. Exposed as a notifier so code
/// running without a BuildContext (deep-link routing in [NotificationTapRouter])
/// can switch tabs. HomePage both listens to and writes this.
final ValueNotifier<int> homeTabIndex = ValueNotifier<int>(homeInboxTabIndex);
