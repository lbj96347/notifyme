# iOS Home Screen Widget — App Group setup

This documents the iOS-native plumbing for the `home_widget` package and the
WidgetKit extension that shares data with the Flutter app. The App Group wiring
lets both sides read/write the same shared container. Two extensions are involved:
the **WidgetKit extension** (`ios/NotifyMeWidget/*.swift`) that draws the
home-screen widget, and the **Notification Service Extension**
(`ios/NotificationService/`) that keeps the widget fresh between app launches (see
*Refresh model*).

Both extension targets are **already wired into the committed
`Runner.xcodeproj/project.pbxproj`** — their source files, build phases, embed
steps, entitlements, and the shared membership of `NotifyMeWidgetSnapshot.swift`
across both targets — so a normal `open ios/Runner.xcworkspace` / `flutter build
ios` picks them up without manual target creation. The *Manual Xcode steps*
section below is retained as the reference for **reproducing** that wiring if you
regenerate the project or the pbxproj entries are lost.

## Refresh model

The widget **never touches Firestore or Firebase directly** — the widget process
can't reach the network with the user's auth session. It only ever renders the
JSON snapshot mirrored into the shared App Group container. Three mechanisms keep
that snapshot current, in order of authority:

1. **App-open sync — the source of truth.** While the app runs, after each inbox
   load/refresh it calls `HomeWidgetService.sync` (`lib/features/widget/
   home_widget_service.dart`) with the newest notifications, which **overwrites
   the whole snapshot** from Firestore and asks the OS to redraw. This is the
   authoritative refresh; everything below is reconciled by it the next time the
   app is foregrounded.
2. **Incoming notifications — optimistic mirror via the Notification Service
   Extension.** Each push is sent with `mutable-content: 1` (set by the backend
   in `firebase_functions/src/messaging.ts`), so iOS hands every delivery to the
   `NotificationService` extension on its own background process **even when the
   app is backgrounded or terminated**, before the banner is shown. The extension
   parses the push and **prepends** it to the App Group snapshot using the *same*
   schema the widget consumes (`NotifyMeWidgetItem` / `NotifyMeWidgetKeys`, shared
   from `NotifyMeWidgetSnapshot.swift`), recomputes the unread count and write
   timestamp, and reloads the timeline. It is purely additive: items are de-duped
   by id, the set is bounded to `maxItems` (10, mirroring
   `HomeWidgetService.defaultMaxItems`), and the whole thing is best-effort —
   any missing/corrupt piece simply skips the mirror without altering the banner.
   When the app next runs, app-open sync overwrites this optimistic state from the
   authoritative source.
3. **Hourly timeline backstop.** `NotifyMeWidgetProvider` reloads on its own
   roughly hourly so relative times advance and the staleness badge can trip even
   if neither of the above fires; it re-reads the same snapshot and never fetches
   data itself.

Net effect: the widget reflects new notifications within seconds of delivery
(without opening the app) while the app remains the single source of truth that
reconciles the snapshot on next launch.

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
- `NotifyMeWidgetView.swift` — SwiftUI surface across the three system families
  **and** the three Lock Screen / StandBy accessory families (iOS 16+, see *Lock
  Screen widgets* below):
  an empty/placeholder state, a **small** single-card readout of the latest
  notification, and **medium/large** layouts that render that same latest
  notification on the lit "beeper" LCD — the retro screen styling shared with the
  empty state (monospaced ink on the olive panel, a block cursor trailing the
  title, status LED + `CATEGORY · time` footer), with large affording more body
  lines than medium. The LCD panel deep-links to the message detail and the
  header deep-links to the inbox. The small tile deep-links the latest
  notification via `widgetURL` (inner `Link`s are ignored on small widgets).
  Every family is hardened against degenerate data: a **stale** badge replaces
  the unread pill when the snapshot is past `staleThreshold`; blank
  titles/bodies/categories use their display fallbacks; unknown statuses fall
  back to the info color; every line is clamped (the title scales down before it
  truncates, body/footer truncate at the tail) so the fixed canvas can't
  overflow; and a row with no usable id deep-links to the inbox. The `#if DEBUG`
  previews include dedicated `.stale` and `.edgeCases` fixtures, plus a full
  accessory-family state matrix (unread / empty / stale / clamp / 99+) and a
  `.highVolume` fixture that exercises the `99+` count cap.
- `NotifyMeWidgetBundle.swift` — `@main` `WidgetBundle`. `kind == "NotifyMeWidget"`
  matches `HomeWidgetService.defaultIosWidgetName`. `supportedFamilies` lists the
  three system families on every OS and appends the three `.accessory*` families
  behind an `#available(iOS 16, *)` check, so the same widget surfaces on the Home
  Screen and the Lock Screen from one declaration.
- `Info.plist` — `com.apple.widgetkit-extension` extension point.
- `NotifyMeWidget.entitlements` — App Group (see below).

These files are members of the `NotifyMeWidget` target in the committed pbxproj.
A standalone editor (or a SourceKit index that hasn't picked up the target
membership yet) may still flag "cannot find type in scope" / `@main` until the
target is compiled together — that's editor noise, not a build problem.

## Lock Screen widgets (iOS 16+)

The same `NotifyMeWidget` also installs on the **Lock Screen** (and StandBy)
through WidgetKit's three accessory families. No extra target, entitlement, or
App Group is required — the accessory families are appended to the bundle's
`supportedFamilies` behind an `#available(iOS 16, *)` check, and they read the
**same** App Group snapshot as the Home Screen widget, so everything in the
*Refresh model* section (app-open sync, push-driven mirror, hourly backstop)
keeps them current the same way.

- **iOS 16 or later is required for the Lock Screen.** The accessory families
  (`.accessoryInline`, `.accessoryCircular`, `.accessoryRectangular`) did not
  exist before WidgetKit on iOS 16. On iOS 14–15 the app and Home Screen widget
  still work; only the Lock Screen surfaces are absent. (The extension target
  itself floors at iOS 14.0 — `IPHONEOS_DEPLOYMENT_TARGET = 14.0` — and the
  accessory code is guarded so it simply isn't compiled in on older OSes.)
- The accessory views render **monochrome** (the system tints them) over
  `AccessoryWidgetBackground`, so the retro olive/LCD palette is intentionally
  dropped there; status is carried by a distinct SF Symbol per state rather than
  color. The three layouts:
  - **Inline** (`.accessoryInline`) — one line beside the clock: a compact unread
    tally leading with the count (`3 new · CI passed`), degrading to
    `No new messages` when caught up.
  - **Circular** (`.accessoryCircular`) — an unread count under a bell glyph (a
    struck-through bell when caught up); large counts cap at `99+`.
  - **Rectangular** (`.accessoryRectangular`) — the flagship: the beeper LCD
    redrawn for the Lock Screen with a header readout (brand + unread tally / stale
    flag), the latest headline with a block cursor, and a status/category/time
    footer. Idle reads `ALL CLEAR`.
- **Deep links work identically** — tapping the accessory widget opens the app via
  the same `notifyme://…` scheme. The accessory families are single whole-widget
  tap targets (`widgetURL`), like the small Home Screen tile, so the whole widget
  routes to the latest notification's detail (falling back to the inbox).

## Notification Service Extension source (skeleton, already in the repo)

`ios/NotificationService/` holds the extension that mirrors incoming pushes into
the widget snapshot between app launches (see *Refresh model*):

- `NotificationService.swift` — the `UNNotificationServiceExtension` subclass.
  `didReceive(...)` calls `WidgetSnapshotWriter.record(...)` (best-effort, never
  blocks or alters the banner) then delivers the unchanged content. The
  `WidgetSnapshotWriter` parses the FCM `data` block (falling back to `aps.alert`
  for title/body), prepends a `NotifyMeWidgetItem` to the App Group snapshot,
  de-dupes by id, trims to `maxItems` (10), recomputes unread/timestamp, and calls
  `WidgetCenter.reloadTimelines`. It does **not** import Firebase or hit the
  network.
- `Info.plist` — `com.apple.usernotifications.service` extension point.
- `NotificationService.entitlements` — the **same** App Group as the widget.

This target shares `NotifyMeWidgetSnapshot.swift` with the widget target (it owns
the `NotifyMeWidgetItem` / `NotifyMeWidgetKeys` types), so the snapshot it writes
is byte-compatible with what the widget reads. That shared membership — plus the
`NotificationService` target, its embed step, and entitlements — is already
wired in the committed pbxproj (the manual step below documents how to recreate
it).

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
- `ios/NotifyMeWidget/NotifyMeWidget.entitlements` and
  `ios/NotificationService/NotificationService.entitlements` — ready-to-use
  entitlements files with the **same** App Group, assigned to the widget and
  Notification Service Extension targets respectively.
- `ios/Runner.xcodeproj/project.pbxproj` — both extension targets
  (`NotifyMeWidget`, `NotificationService`) are wired in: file references, Sources
  build phases, the Runner's *Embed App Extensions* step, target dependencies,
  per-config build settings (`INFOPLIST_FILE`, `CODE_SIGN_ENTITLEMENTS`,
  `PRODUCT_BUNDLE_IDENTIFIER`, `IPHONEOS_DEPLOYMENT_TARGET = 14.0`), and the shared
  membership of `NotifyMeWidgetSnapshot.swift` across both targets.

## Manual Xcode steps (already applied — reference for regenerating)

The wiring below is **already present** in the committed pbxproj; you do not need
to perform it for a normal build. It is documented because adding an extension
target via Xcode mutates `Runner.xcodeproj/project.pbxproj` in ways that are unsafe
to hand-edit — so if you regenerate the project or lose the wiring, reproduce it in
Xcode (`open ios/Runner.xcworkspace`):

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

3. **Add the Notification Service Extension target** (keeps the widget fresh on
   incoming pushes — see *Refresh model*):
   - *File → New → Target… → Notification Service Extension*. Name it
     `NotificationService`.
   - **Replace the generated stub with the committed source.** Delete the
     generated `NotificationService.swift`/`Info.plist` (move to trash) and
     *Add Files to "Runner"…* the skeleton in `ios/NotificationService/`:
     `NotificationService.swift` and `Info.plist` — with **target membership =
     NotificationService**. Point the target's `INFOPLIST_FILE` at
     `NotificationService/Info.plist`.
   - **Also add `ios/NotifyMeWidget/NotifyMeWidgetSnapshot.swift` to this
     target's membership** (check both `NotifyMeWidget` *and* `NotificationService`
     in the File Inspector). The extension reuses its `NotifyMeWidgetItem` /
     `NotifyMeWidgetKeys` types, so the snapshot it writes stays byte-compatible
     with what the widget reads.
   - In the new target's *Signing & Capabilities*, add **App Groups** and check
     `group.com.asktobuild.notifyme`. Point its `CODE_SIGN_ENTITLEMENTS` at
     `NotificationService/NotificationService.entitlements` (already created here).

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

The Swift surface (decoding, the three system families, the three iOS 16+
accessory families, staleness, deep links) needs a real WidgetKit build; the
extension targets are already wired (see *Manual Xcode steps*), so just open the
workspace and run:

1. **SwiftUI previews (fastest loop, no full build).** Open
   `NotifyMeWidgetView.swift` in Xcode and use the canvas. The `#if DEBUG`
   previews include `.sample`, `.stale`, `.edgeCases`, and `.highVolume`
   fixtures — confirm:
   - all three system families render (small / medium / large);
   - the three accessory families render (inline / circular / rectangular), each
     with its labeled state matrix (unread / empty / stale / clamp / 99+) — these
     previews are behind `#available(iOS 16, *)`, so use an iOS 16+ preview device;
   - `.highVolume` (128 unread) caps the count at `99+` in the circular dial and
     the rectangular `99+ NEW` header tag;
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
     size. Confirm every size shows the latest notification, the unread count,
     and a fresh relative time. Add the same widget in all three sizes to compare.
   - **Lock Screen widgets (iOS 16+ device/Simulator).** Lock the device, then
     long-press the Lock Screen → **Customize** → tap the widget area below the
     clock (rectangular) or the row above it (inline, beside the date). Tap **+**
     in the widget gallery, find **NotifyMe**, and add each accessory size:
     - the **inline** slot (above the clock) shows the unread tally / headline;
     - a **circular** slot shows the count under a bell (or struck-through bell
       when caught up), capping at `99+`;
     - the **rectangular** slot shows the LCD-style header / headline / footer.
     Confirm they render monochrome (no olive palette), reflect the latest
     notification and unread count, and update after a new webhook fires. On
     iOS 14–15 the accessory sizes won't appear in the gallery — that's expected.
   - **Deep links:** tap the LCD panel (medium/large) or the small tile → the app
     opens that notification's detail; tap the header → lands on the inbox tab.
     Tapping any **accessory** (Lock Screen) widget opens the latest
     notification's detail too (single whole-widget tap target). Verify this from
     all three app states:
     foreground, backgrounded, and **terminated** (swipe-kill the app first, then tap — this
     exercises `initiallyLaunchedFromHomeWidget()`).
   - **Push-driven refresh (Notification Service Extension):** with the app
     **backgrounded or swipe-killed**, fire a webhook notification and confirm the
     widget shows the new item within a few seconds — without opening the app. This
     exercises `NotificationService` mirroring the push into the snapshot. Then
     foreground the app and confirm the snapshot reconciles (app-open sync
     overwrites it from Firestore; no duplicate row for the just-pushed item).
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
