# Firebase Setup

NotifyMe is self-hosted: you deploy the whole stack into **your own Firebase
project**. Nothing here points at a central NotifyMe server, and there are no
hardcoded project IDs — every value below comes from the project *you* create.

This guide walks the full path: create a project → enable services → register
your iOS/Android apps → wire up the Flutter client → deploy the rules and the
webhook function → fire a test webhook and watch it land on your phone.

> The repo is still **pre-implementation** (only `PRD.md` and scaffolding
> READMEs exist today). The CLI commands below describe the target workflow;
> `flutter_app/` and `firebase_functions/` need to be scaffolded before
> `flutter run` / `firebase deploy` will do anything.

---

## 0. Prerequisites

| Tool | Why | Check |
|------|-----|-------|
| [Node.js](https://nodejs.org) 18+ | Firebase CLI + Cloud Functions runtime | `node -v` |
| [Flutter SDK](https://docs.flutter.dev/get-started/install) | builds the mobile client | `flutter --version` |
| [Firebase CLI](https://firebase.google.com/docs/cli) | deploy rules/functions, manage project | `firebase --version` |
| Xcode (macOS) | build/sign iOS, configure APNs | `xcodebuild -version` |
| Android Studio | build Android, manage SDK | — |
| A Google account | owns the Firebase project | — |

> **Cloud Functions requires billing.** The webhook receiver is a Cloud
> Function, so the project must be on the **Blaze (pay-as-you-go)** plan. The
> free tier is generous (2M invocations/month) and personal use stays at $0,
> but a billing account *must* be attached or `firebase deploy --only functions`
> will fail. See [Troubleshooting](#troubleshooting).

---

## 1. Create a Firebase project

1. Go to the [Firebase Console](https://console.firebase.google.com/).
2. **Add project** → give it a name (e.g. `notifyme-yourname`). Firebase derives
   a globally-unique **project ID** (e.g. `notifyme-yourname-3f9c2`) — note it,
   you'll need it for the CLI.
3. Google Analytics: enable it (NotifyMe uses Analytics — see step 7) and create
   or pick an Analytics account.
4. Wait for provisioning, then **Continue**.

Keep your **project ID** handy. Because NotifyMe is self-host-friendly, the ID
is never committed to source — it lives only in your local config and the
generated `firebase_options.dart` / platform config files.

---

## 2. Enable Authentication

The Flutter app signs users in, and the webhook function maps a `userToken` to
the authenticated `uid`.

1. Console → **Build → Authentication → Get started**.
2. **Sign-in method** tab → enable at least one provider:
   - **Email/Password** — simplest for a personal/self-hosted deploy.
   - **Google** — optional; if you enable it on iOS you'll later add a reversed
     client ID URL scheme (it's in `GoogleService-Info.plist`).
3. Save.

---

## 3. Enable Firestore

All three collections (`users`, `devices`, `notifications`) live in Firestore,
keyed by `uid`.

1. Console → **Build → Firestore Database → Create database**.
2. Pick a **location** (region) — choose one near you/your senders. This is
   permanent.
3. Start in **production mode** (locked). We deploy real rules in step 10; never
   ship test-mode rules (they allow open read/write).

---

## 4. Enable Cloud Messaging (FCM)

FCM delivers the push to the phone.

1. Console → **Project settings (gear) → Cloud Messaging**. The **Firebase Cloud
   Messaging API (V1)** is enabled by default on new projects.
2. iOS additionally needs an **APNs key** — configured in step 8.4 below.

No per-collection setup is needed here; the Flutter app registers each device's
FCM token into the `devices` collection, and the function reads those tokens.

---

## 5. Enable Cloud Functions

The webhook receiver is a Cloud Function — the only externally-reachable surface.

1. Console → **Build → Functions → Get started**.
2. If prompted, **upgrade to the Blaze plan** and attach a billing account
   (required — see the billing note above).
3. The actual code lives in `firebase_functions/`; you deploy it in step 9. No
   further console clicks are needed here.

---

## 6. Register the iOS app

1. Console → **Project settings → General → Your apps → Add app → iOS**.
2. **Apple bundle ID** — must match the bundle ID in Xcode (e.g.
   `com.yourname.notifyme`). Use a reverse-DNS ID you control.
3. (Optional) App nickname and App Store ID.
4. **Register app**, then **download `GoogleService-Info.plist`**.
5. Place it at `flutter_app/ios/Runner/GoogleService-Info.plist` and add it to
   the **Runner** target in Xcode (drag into the Runner group, tick *Copy items
   if needed* and the Runner target). FlutterFire (step 8) also generates
   `firebase_options.dart`; both are expected.

---

## 7. Register the Android app

1. Console → **Project settings → General → Your apps → Add app → Android**.
2. **Android package name** — must match `applicationId` in
   `flutter_app/android/app/build.gradle` (e.g. `com.yourname.notifyme`).
3. **Debug signing certificate SHA-1** — optional for FCM, but required if you
   use Google Sign-In. Get it with:
   ```bash
   cd flutter_app/android && ./gradlew signingReport
   # or:
   keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey \
     -storepass android -keypass android
   ```
4. **Register app**, then **download `google-services.json`**.
5. Place it at `flutter_app/android/app/google-services.json`.

> **Analytics (step 1)** is wired up automatically once these apps are
> registered and the config files are in place — the Firebase SDK in the Flutter
> client reports to the Analytics account you selected. No extra steps.

---

## 8. Install the Firebase CLI, log in, select the project, configure FlutterFire

### 8.1 Install the Firebase CLI

```bash
npm install -g firebase-tools
firebase --version
```

### 8.2 Log in

```bash
firebase login
```

This opens a browser for Google OAuth. On a headless/CI machine use
`firebase login:ci` to mint a token instead.

### 8.3 Select the project

From the repo root, bind this working copy to your project:

```bash
firebase use --add
# choose your project ID from the list, give it an alias like "default"
```

This writes `.firebaserc` (an alias → project-ID map). Because it's local
config, it's fine to keep the alias generic so others can `firebase use --add`
their *own* project.

### 8.4 Configure APNs for iOS (push won't work without this)

iOS pushes route through Apple, so FCM needs an **APNs authentication key**:

1. In the [Apple Developer portal](https://developer.apple.com/account) →
   **Certificates, Identifiers & Profiles → Keys → +** → enable **Apple Push
   Notifications service (APNs)** → download the `.p8` file (you can only
   download it once). Note the **Key ID** and your **Team ID**.
2. Firebase Console → **Project settings → Cloud Messaging → Apple app
   configuration → APNs Authentication Key → Upload**. Provide the `.p8`, Key
   ID, and Team ID.
3. In Xcode, enable the **Push Notifications** capability and the **Background
   Modes → Remote notifications** capability on the Runner target.

### 8.5 Configure FlutterFire

[FlutterFire](https://firebase.flutter.dev/docs/cli) generates
`firebase_options.dart` so the Flutter app initializes against *your* project.

```bash
dart pub global activate flutterfire_cli
cd flutter_app
flutterfire configure
# pick your project; select ios + android platforms
```

This regenerates the platform config and writes
`flutter_app/lib/firebase_options.dart`. Ensure the app calls:

```dart
await Firebase.initializeApp(
  options: DefaultFirebaseOptions.currentPlatform,
);
```

---

## 9. Deploy Firestore rules and the webhook function

From the repo root (where `firebase.json`, `firestore.rules`, and the
`firebase_functions/` source live):

```bash
# Install function deps first
cd firebase_functions && npm install && cd ..

# Deploy Firestore security rules
firebase deploy --only firestore:rules

# Deploy the webhook Cloud Function
firebase deploy --only functions

# …or everything at once
firebase deploy
```

On success the CLI prints the function's HTTPS URL, e.g.:

```
Function URL (webhook): https://<region>-<your-project>.cloudfunctions.net/webhook
```

**Security rules** must scope every read/write to the signed-in user's own
`uid`. The expected shape (lives in `firestore.rules`):

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{uid}        { allow read, write: if request.auth.uid == uid; }
    match /devices/{id}       { allow read, write: if request.auth.uid == resource.data.uid; }
    match /notifications/{id} { allow read, write: if request.auth.uid == resource.data.uid; }
  }
}
```

---

## 10. Test the webhook

Find your personal **`userToken`** (the routing key the function maps to your
`uid`) — generated for your account by the app/function and stored against your
user record.

Send a test notification using the shared payload contract:

```bash
curl -X POST \
  "https://<region>-<your-project>.cloudfunctions.net/webhook/<your-user-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Build finished",
    "message": "All tests passed on main",
    "category": "claude",
    "status": "success",
    "url": "https://github.com/you/repo/actions/runs/123"
  }'
```

What should happen, end to end:

```
curl → Cloud Function (webhook/{userToken}) → Firestore (notifications) → FCM push → phone → open app → notification detail
```

Verify each hop:
- **Function** received it: `firebase functions:log` (or Console → Functions →
  Logs). A 200 means the doc was written and the push dispatched.
- **Firestore**: a new doc appears in `notifications` with your `uid`.
- **Phone**: the push arrives; tapping it opens the app to the detail view (the
  `url` field makes it tappable through to the PR/run/dashboard).

> `status` maps to a color in the app — green=success, red=error,
> yellow=warning, blue=info. `category` groups the inbox. Keep this payload in
> sync with `firebase_functions/`, `flutter_app/`, and the `examples/` snippets.

---

## Troubleshooting

### Firebase billing / Cloud Functions
- **`Your project must be on the Blaze (pay-as-you-go) plan to complete this
  command`** — Console → **Upgrade** (bottom-left) → Blaze, attach a billing
  account. Functions cannot deploy on the free Spark plan.
- Set a **budget alert** (Google Cloud Console → Billing → Budgets) so you're
  notified before any spend. Personal usage typically stays within the free
  monthly allotment.
- First deploy may fail while Google enables `cloudfunctions`,
  `cloudbuild`, and `artifactregistry` APIs — wait a minute and re-run
  `firebase deploy --only functions`.

### FCM tokens
- **No push arrives, but the Firestore doc was written** → the device's FCM
  token is missing or stale. Confirm the app requested notification permission
  and wrote a token into `devices`. FCM tokens **rotate**; the app must listen
  to `onTokenRefresh` and update the `devices` doc, and the function should
  prune tokens that come back `messaging/registration-token-not-registered`.
- **`SenderId mismatch` / `messaging/mismatched-credential`** → the config file
  on the device belongs to a different Firebase project than the function is
  deployed to. Re-run `flutterfire configure` and redownload
  `GoogleService-Info.plist` / `google-services.json`.
- Test a raw token quickly from Console → **Cloud Messaging → Send test
  message** before blaming the function.

### APNs for iOS
- **Works on Android, silent on iOS** → almost always APNs. Re-check step 8.4:
  the `.p8` key, Key ID, and Team ID must be uploaded under Cloud Messaging, and
  the bundle ID must match.
- **iOS Simulator never receives remote pushes** — APNs requires a **real
  device** (recent simulators support local notifications only). Test on
  hardware.
- Push capability missing → enable **Push Notifications** + **Background Modes →
  Remote notifications** in Xcode → Signing & Capabilities.
- Provisioning profile must include the Push Notifications entitlement; let Xcode
  *Automatically manage signing* or regenerate the profile after enabling the
  capability.
- Foreground messages on iOS need `setForegroundNotificationPresentationOptions`
  (alert/badge/sound) or you'll see nothing while the app is open.

### General
- **`HTTP Error: 403, Permission denied`** on deploy → wrong project selected;
  run `firebase use` to check, `firebase use --add` to fix.
- **Rules deploy but reads fail in-app** → confirm the user is signed in
  (`request.auth` is null when unauthenticated) and that `notifications`/
  `devices` docs actually carry a `uid` field matching the signed-in user.
- **`firebase: command not found`** → the global npm bin isn't on `PATH`, or
  reinstall with `npm install -g firebase-tools`.

---

## Quick reference

```bash
npm install -g firebase-tools          # install CLI
firebase login                         # auth
firebase use --add                     # bind to YOUR project
flutterfire configure                  # generate firebase_options.dart
firebase deploy --only firestore:rules # ship rules
firebase deploy --only functions       # ship webhook
firebase functions:log                 # watch the function
```
