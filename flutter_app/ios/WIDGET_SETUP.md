# iOS Home Screen Widget — App Group setup

This documents the iOS-native plumbing for the `home_widget` package and the
WidgetKit extension that shares data with the Flutter app. The App Group wiring
lets both sides read/write the same shared container; the WidgetKit extension
**source files exist** (`ios/NotifyMeWidget/*.swift`) but are **not yet added to
an Xcode target** — that registration is the manual step below.

## WidgetKit extension source (skeleton, already in the repo)

`ios/NotifyMeWidget/` holds a ready-to-build SwiftUI WidgetKit skeleton:

- `NotifyMeWidgetSnapshot.swift` — decodes the shared JSON snapshot
  (`NotifyMeWidgetKeys` + `NotifyMeWidgetItem`/`NotifyMeWidgetSnapshot`). Mirrors
  the Dart `HomeWidgetService` wire contract exactly; missing/corrupt data
  degrades to an empty snapshot rather than throwing. Decoding is per-field
  tolerant — a missing/wrong-typed field on one item falls back to a safe default
  (`status` → `info`, others → empty) instead of dropping the item, and item
  display helpers cover blanks (`displayTitle`/`hasBody`/`displayCategory`).
  `isStale(asOf:)` flags snapshots older than `staleThreshold` (24h).
- `NotifyMeWidgetProvider.swift` — `TimelineProvider` reading the snapshot, with
  an hourly reload backstop on top of the app's `updateWidget(...)` triggers.
- `NotifyMeWidgetTheme.swift` — the retro palette mirrored from
  `lib/shared/retro_palette.dart` (`RetroWidgetPalette`), a `Color(hex:)` helper,
  and `RetroRelativeTime` for compact `now`/`5m`/`2h`/`3d` timestamps.
- `NotifyMeWidgetView.swift` — SwiftUI surface across all three system families:
  an empty/placeholder state, a **small** single-card readout of the latest
  notification, a compact **medium** list (latest three), and a **large "beeper
  readout"** — the latest five notifications styled like the app icon's pager LCD
  (status LED, title, body preview, `CATEGORY · time` footer), with a "More"
  target opening the inbox. Medium/large rows are deep-link `Link`s; the small
  tile deep-links the latest notification via `widgetURL` (inner `Link`s are
  ignored on small widgets). Every family is hardened against degenerate data:
  a **stale** badge replaces the unread pill when the snapshot is past
  `staleThreshold`; blank titles/bodies/categories use their display fallbacks;
  unknown statuses fall back to the info color; long titles/bodies cap with tail
  truncation while the relative time keeps layout priority; and rows with no
  usable id deep-link to the inbox (with `ForEach` keyed by position so blank
  ids can't collide). The `#if DEBUG` previews include dedicated `.stale` and
  `.edgeCases` fixtures.
- `NotifyMeWidgetBundle.swift` — `@main` `WidgetBundle`; `kind == "NotifyMeWidget"`
  matches `HomeWidgetService.defaultIosWidgetName`.
- `Info.plist` — `com.apple.widgetkit-extension` extension point.
- `NotifyMeWidget.entitlements` — App Group (see below).

SourceKit will flag "cannot find type in scope" / `@main` warnings on these
files until they're compiled together inside the extension target created in
Xcode — that's expected for loose files with no target membership.

## App Group identifier

```
group.com.asktobuild.notifyme
```

Derived from the app bundle id `com.asktobuild.notifyme`. If you fork/rebrand,
change the App Group everywhere it appears (entitlements files below, the Flutter
`HomeWidget.setAppGroupId(...)` call, and the widget's `UserDefaults(suiteName:)`).

## What's already done in the repo

- `pubspec.yaml` — added `home_widget`.
- `ios/Runner/Runner.entitlements` — added the `com.apple.security.application-groups`
  array containing `group.com.asktobuild.notifyme`. This is already referenced by
  the Runner target (`CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements`).
- `ios/NotifyMeWidget/NotifyMeWidget.entitlements` — a ready-to-use entitlements
  file with the **same** App Group, to be assigned to the future widget extension
  target (see manual steps).

## Manual Xcode steps (cannot be scripted reliably)

Adding a WidgetKit extension target mutates `Runner.xcodeproj/project.pbxproj` in
ways that are unsafe to hand-edit. Do these in Xcode (`open ios/Runner.xcworkspace`):

1. **Register the App Group in your Apple Developer account / Signing & Capabilities.**
   - Select the **Runner** target → *Signing & Capabilities* → **+ Capability** →
     **App Groups** → ensure `group.com.asktobuild.notifyme` is present and checked.
     (The entitlements file already lists it; this makes the provisioning profile
     include it.)

2. **Add the widget extension target** and wire it to the existing source:
   - *File → New → Target… → Widget Extension*. Name it `NotifyMeWidget`.
   - Uncheck "Include Configuration Intent" (the skeleton uses
     `StaticConfiguration`).
   - Set the extension's deployment target to **iOS 14.0+** (WidgetKit minimum).
     Note the app itself floors at iOS 13.0 — that's fine; the extension can be
     higher.
   - **Replace the generated stub with the committed source.** Xcode scaffolds a
     `NotifyMeWidget.swift` + `Info.plist` (and maybe an Assets catalog) inside a
     new `NotifyMeWidget/` group. Delete the generated `.swift`/`Info.plist`
     (move to trash) and instead *Add Files to "Runner"…* the skeleton already in
     `ios/NotifyMeWidget/`: `NotifyMeWidgetSnapshot.swift`,
     `NotifyMeWidgetProvider.swift`, `NotifyMeWidgetTheme.swift`,
     `NotifyMeWidgetView.swift`,
     `NotifyMeWidgetBundle.swift`, and `Info.plist` — with **target membership =
     NotifyMeWidget** (not Runner). Point the target's `INFOPLIST_FILE` build
     setting at `NotifyMeWidget/Info.plist`.
   - In the new target's *Signing & Capabilities*, add **App Groups** and check
     `group.com.asktobuild.notifyme`. Point its `CODE_SIGN_ENTITLEMENTS` build
     setting at `NotifyMeWidget/NotifyMeWidget.entitlements` (already created here),
     or merge the App Group into the file Xcode generates.

## Flutter-side usage (when implementing)

```dart
import 'package:home_widget/home_widget.dart';

// Call once at startup before reading/writing widget data:
await HomeWidget.setAppGroupId('group.com.asktobuild.notifyme');

// Write data the widget will read:
await HomeWidget.saveWidgetData<String>('latest_title', notification.title);
await HomeWidget.updateWidget(iOSName: 'NotifyMeWidget');
```

On the Swift side the extension reads the same keys via
`UserDefaults(suiteName: "group.com.asktobuild.notifyme")`.

## Deep links (widget tap → app navigation)

The widget makes its rows tappable with deep-link URLs that the app routes:

| URL                          | Destination                          |
| ---------------------------- | ------------------------------------ |
| `notifyme://inbox`           | the inbox tab (header / empty state) |
| `notifyme://notification/{id}` | that notification's detail screen   |

These are owned by the app: the scheme is registered in
`ios/Runner/Info.plist` (`CFBundleURLTypes`) and
`android/app/src/main/AndroidManifest.xml` (a `VIEW` intent-filter on the
singleTop `MainActivity`). The Dart side consumes them in
`lib/features/notifications/notification_tap_router.dart` via `home_widget`'s
`widgetClicked` stream (app already running) and `initiallyLaunchedFromHomeWidget()`
(tap that cold-started the app) — so navigation works whether the app was
foregrounded, backgrounded, or terminated. A `notification/{id}` whose document
can't be resolved (deleted, or not the signed-in user's) falls back to the inbox.

### iOS WidgetKit — emitting the links

Wrap each row in a `Link`, and give the whole widget a default tap target:

```swift
Link(destination: URL(string: "notifyme://notification/\(item.id)")!) {
    NotifyMeRow(item: item)
}
// ...and for the header / empty state:
.widgetURL(URL(string: "notifyme://inbox"))
```

### Android App Widget — emitting the links

Build the tap `PendingIntent` with `home_widget`'s helper so the URI arrives as
`MainActivity`'s intent data:

```kotlin
val intent = HomeWidgetLaunchIntent.getActivity(
    context, MainActivity::class.java,
    Uri.parse("notifyme://notification/$id"),
)
```

## Validation

### Automated (Dart) — what's covered without a device

The two sides of the bridge are exercised by Flutter unit/widget tests that need
no simulator, App Group, or platform channel:

- **`test/home_widget_service_test.dart`** — the *writer*. Asserts the exact wire
  contract the Swift `NotifyMeWidgetSnapshot` decodes: item keys/JSON shape,
  unread count (including items past `maxItems`), `updated` timestamp, body
  preview/whitespace-collapse/truncation, `url`-omitted-when-empty, one-time App
  Group binding, and `clear()`. The **degenerate-data** cases (blank id/title/
  category written through verbatim, all-whitespace body collapsing to `""`,
  unknown status passed through, blank `url` omitted) pin the writer's half of
  the contract whose other half is the Swift renderer's display fallbacks
  (`displayTitle`/`hasBody`/`displayCategory`, unknown-status → `info`).
- **`test/notification_tap_router_test.dart`** — the *reader*. Drives the
  `notifyme://…` deep links through a fake `home_widget` launch client: detail
  link resolves, missing/empty id falls back to inbox, `notifyme://inbox` pops to
  root + selects the inbox tab, a cold-start tap routes after first frame,
  unknown hosts / foreign schemes / `null` clicks are ignored, and `dispose()`
  stops routing.

Run them with `flutter test test/home_widget_service_test.dart
test/notification_tap_router_test.dart`. These do **not** compile or exercise the
Swift WidgetKit code — that needs the manual pass below.

### Manual — iOS Simulator / device WidgetKit behavior

The Swift surface (decoding, the three families, staleness, deep links) only runs
once the extension target exists (see *Manual Xcode steps*). After wiring it:

1. **SwiftUI previews (fastest loop, no full build).** Open
   `NotifyMeWidgetView.swift` in Xcode and use the canvas. The `#if DEBUG`
   previews include `.sample`, `.stale`, and `.edgeCases` fixtures — confirm:
   - all three families render (small / medium / large);
   - `.edgeCases` shows the blank-field fallbacks (`(no title)`, suppressed empty
     body, `GENERAL` category) and long title/body tail-truncate while the
     `CATEGORY · time` footer keeps its relative time visible;
   - `.stale` shows the warning-toned stale badge in place of the unread pill
     (glyph-only on small).

2. **End-to-end on the Simulator.**
   - `flutter run` the app on an iOS 14+ Simulator, sign in, and trigger a couple
     of webhook notifications so the inbox (and therefore `HomeWidgetService.sync`)
     has data.
   - Long-press the home screen → **+** → add the **NotifyMe** widget in each
     size. Confirm it shows the latest notifications, the unread count, and a
     fresh relative time. Add the same widget in all three sizes to compare.
   - **Deep links:** tap a row (medium/large) → the app opens that notification's
     detail; tap the small tile → opens the latest; tap **More** / the header →
     lands on the inbox tab. Verify this from all three app states: foreground,
     backgrounded, and **terminated** (swipe-kill the app first, then tap — this
     exercises `initiallyLaunchedFromHomeWidget()`).
   - **Sign-out:** sign out in the app and confirm the widget redraws to its empty
     state (driven by `HomeWidgetService.clear`).

3. **Staleness.** The 24h `staleThreshold` is impractical to wait out, so verify
   it one of two ways: temporarily lower `staleThreshold` in
   `NotifyMeWidgetSnapshot.swift` and confirm the badge appears after the wait, or
   rely on the `.stale` preview fixture (step 1). The provider now stamps entries
   with the real `Date()` (not `updatedAt`), so relative times advance and the
   threshold can actually trip — sanity-check that a freshly synced widget is
   **not** flagged stale.

4. **Physical device caveats.** App Group entitlements must be present in the
   provisioning profiles for **both** the Runner and the widget target (the
   Simulator is lax about this; a device is not). If the widget renders its empty
   state on-device despite the app having data, the App Group binding is the first
   thing to check — confirm `group.com.asktobuild.notifyme` is enabled and checked
   on both targets' *Signing & Capabilities*.
