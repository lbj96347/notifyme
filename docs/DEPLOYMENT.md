# Deployment

This is the operational runbook for shipping NotifyMe into **your own Firebase
project**. It covers configuring Firebase, building the Flutter apps, deploying
Firestore rules + indexes, deploying the webhook Cloud Function, and verifying
end-to-end delivery — plus rollback and common failure notes.

> **First time?** If you have never created the Firebase project or registered
> the iOS/Android apps, do the one-time setup in
> [FIREBASE_SETUP.md](FIREBASE_SETUP.md) first (create project, enable Auth /
> Firestore / FCM / Functions, register apps, APNs key, `flutterfire configure`).
> This guide assumes that groundwork is done and focuses on the
> **build → deploy → verify** loop you repeat on every release.

The end-to-end flow you are deploying:

```
external system → Cloud Function POST /webhook/{userToken}
              → Firestore (notifications) → FCM push → phone → open app → detail
```

---

## 0. Prerequisites

| Tool | Version | Check |
| --- | --- | --- |
| Firebase CLI | latest | `firebase --version` |
| Node.js | 20 (matches `firebase_functions/package.json` `engines`) | `node -v` |
| Flutter SDK | Dart `^3.9.2` (see `flutter_app/pubspec.yaml`) | `flutter --version` |
| Java JDK | 11+ (only for the Firestore emulator / rules tests) | `java -version` |
| Logged in | — | `firebase login` |

Your project must be on the **Blaze (pay-as-you-go)** plan — Cloud Functions
cannot deploy on the free Spark plan.

Confirm the CLI is pointed at the right project before every deploy:

```bash
firebase use            # shows the active project + alias
firebase projects:list  # all projects you can access
```

If `.firebaserc` doesn't exist yet, copy the example and set your project id:

```bash
cp .firebaserc.example .firebaserc
firebase use --add      # pick your project, alias it "default"
```

> ⚠️ Self-host invariant: never hardcode a project id into source. The project
> id lives only in `.firebaserc` (git-ignored) and the generated
> `firebase_options.dart` / `google-services.json` / `GoogleService-Info.plist`,
> all of which are git-ignored. A clean checkout must build for *anyone's*
> project.

---

## 1. Configure Firebase

All commands below are run from the **repo root** unless noted.

1. **Select the project** (see above): `firebase use <alias-or-id>`.
2. **Verify config files are present** (generated during one-time setup, not
   committed):
   - `flutter_app/lib/firebase_options.dart` — from `flutterfire configure`
   - `flutter_app/android/app/google-services.json`
   - `flutter_app/ios/Runner/GoogleService-Info.plist`

   If any are missing, re-run:

   ```bash
   cd flutter_app
   flutterfire configure   # pick your project; select ios + android
   cd ..
   ```

3. **Confirm `firebase.json`** wires Firestore (rules + indexes) and the
   `firebase_functions` codebase. It already does in this repo — no edits
   needed.

---

## 2. Build the Flutter apps

Install dependencies and run the test suite first; a green build is the gate for
a release.

```bash
cd flutter_app
flutter pub get
flutter analyze
flutter test          # widget tests; no Firebase init required
```

### Android

```bash
# Debug APK for sideloading / testing
flutter build apk --debug

# Release builds (configure signing in android/ first)
flutter build apk --release          # APK
flutter build appbundle --release    # AAB for Play Store
```

Output: `build/app/outputs/flutter-apk/` (APK) and
`build/app/outputs/bundle/release/` (AAB).

### iOS

```bash
# Requires Xcode + a configured signing team / provisioning profile
flutter build ios --release          # then archive in Xcode, or:
flutter build ipa --release          # produces an .ipa for App Store / ad-hoc
```

Output: `build/ios/ipa/`. Open `ios/Runner.xcworkspace` in Xcode for signing /
upload via Organizer if you prefer.

> **iOS push will not work** without an APNs auth key uploaded to Firebase
> (Project Settings → Cloud Messaging) and the **Push Notifications** +
> **Background Modes → Remote notifications** capabilities enabled on the
> Runner target. See FIREBASE_SETUP.md §8.4 / §6.

> Run on a **physical device** to test push — the iOS Simulator does not receive
> FCM/APNs pushes.

---

## 3. Deploy Firestore rules and indexes

Rules scope every read/write to the authenticated owner's `uid`; notifications
are created server-side only (`allow create: if false`). Deploy them before
pointing real clients at the project.

```bash
# Rules only
firebase deploy --only firestore:rules

# Indexes only (composite indexes from firestore.indexes.json)
firebase deploy --only firestore:indexes

# Both
firebase deploy --only firestore
```

**Validate before deploying** (optional but recommended) by running the rules
tests against the emulator:

```bash
cd firebase_functions
npm install
export JAVA_HOME=$(/usr/libexec/java_home -v 17)   # macOS; needs JDK 11+
npm run test:rules
cd ..
```

Notes:
- Composite indexes can take **minutes to build** after deploy. Queries that
  need a still-building index fail until it's `Enabled` — watch
  Firebase Console → Firestore → Indexes.
- The webhook token lookup (`webhookToken == ?`) uses Firestore's **automatic**
  single-field index, so it needs no entry in `firestore.indexes.json` and works
  on a fresh project immediately.

---

## 4. Deploy the webhook Cloud Function

The function is TypeScript and must be compiled before deploy. The Firebase CLI
runs the `predeploy`/build hooks, but build + lint locally first to catch
errors fast.

```bash
cd firebase_functions
npm install
npm run lint
npm run build          # tsc → lib/
npm test               # pure unit tests, no emulator/credentials
cd ..

# Deploy the function
firebase deploy --only functions
# …or just this one function by name:
firebase deploy --only functions:webhook
```

On success the CLI prints the function URL, e.g.:

```
Function URL (webhook): https://<region>-<project-id>.cloudfunctions.net/webhook
```

Your personal webhook endpoint is then:

```
https://<region>-<project-id>.cloudfunctions.net/webhook/<your-userToken>
```

The `userToken` is the `webhookToken` field on your `users/{uid}` document
(minted at sign-up). It is an unguessable **routing key**, not a verified secret
in the MVP — treat the full URL as sensitive.

> **First deploy of a new project** may prompt to enable the Cloud Functions,
> Cloud Build, and Artifact Registry APIs and to confirm the region. Accept, and
> re-run if it times out provisioning.

Deploy everything in one shot:

```bash
firebase deploy --only firestore,functions
```

---

## 5. Verify webhook delivery

Work outward from the function to the phone.

### 5.1 Smoke-test the endpoint

```bash
curl -i -X POST \
  "https://<region>-<project-id>.cloudfunctions.net/webhook/<your-userToken>" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Deploy check",
    "message": "If you see this on your phone, the pipeline works.",
    "category": "ci",
    "status": "success",
    "url": "https://example.com"
  }'
```

Expected: **`HTTP/2 201`** with body `{"ok":true,"id":"<docId>"}`.

| Response | Meaning |
| --- | --- |
| `201 {ok:true,id}` | Notification persisted; push attempted (best-effort) |
| `400 {ok:false,error,details:[…]}` | Payload failed validation — read `details` |
| `404 {ok:false,error:"unknown webhook token"}` | Token malformed **or** not found (intentionally indistinguishable) |
| `405` + `Allow: POST` | Wrong HTTP method |
| `500 {ok:false,error:"internal error"}` | Write failed — check function logs |

### 5.2 Confirm the Firestore write

Firebase Console → Firestore → `notifications`: a new doc with your `uid`,
`read: false`, and a server `createdAt`. (The function returns `201` even if the
push later fails, so a present doc + no push means the problem is in FCM, not
the webhook.)

### 5.3 Confirm the push reached the phone

- Open the app on a real device while signed in → the device's FCM token is
  registered in `devices`. Confirm a doc exists there for your `uid`.
- Re-send the `curl`. The notification should arrive as a push; tapping it opens
  the app to the detail (and follows `url` when present).
- Tail logs to see the push result:

  ```bash
  firebase functions:log              # recent logs
  firebase functions:log --only webhook
  ```

- The `examples/` directory has copy-paste senders (`bash/`, `claude-code/`,
  `codex-cli/`, `n8n/`, `github-actions/`) using this same contract — use one to
  confirm a real integration end-to-end.

---

## 6. Rollback

Firebase keeps version history; rollback differs per surface.

### Cloud Functions

The CLI does not "undo" a deploy — **redeploy the previous code**:

```bash
git checkout <last-good-ref> -- firebase_functions
cd firebase_functions && npm ci && npm run build && cd ..
firebase deploy --only functions:webhook
```

Or, for a fast revert without a code change, roll back from the **Google Cloud
Console → Cloud Run / Cloud Functions → webhook → Revisions → "Manage traffic"**
and route 100% to the last-known-good revision. To remove a broken function
entirely: `firebase functions:delete webhook` (this stops the webhook from
accepting traffic — only as a last resort).

### Firestore rules

Console → Firestore → Rules → **history** tab lets you view and **roll back to a
prior published ruleset** in one click. From the CLI, re-deploy the previous
`firestore.rules`:

```bash
git checkout <last-good-ref> -- firestore.rules
firebase deploy --only firestore:rules
```

### Firestore indexes

Indexes are additive — a new deploy adds indexes but **does not delete** ones
removed from `firestore.indexes.json` unless you pass `--force`. To remove an
index, delete it in the Console. Rolling back rules/functions does not require
touching indexes.

### Flutter app

Re-publish the previous build artifact (AAB/IPA) from the store console, or
distribute the prior APK. Mobile rollouts aren't instant — use **staged
rollouts** (Play Console) / **phased release** (App Store) so a bad build can be
halted before reaching everyone.

> **Compatibility:** deploy backend changes that the app depends on *before*
> shipping the app, and roll the app back *before* rolling back the backend, so
> a rules/payload change never lands without the client that understands it.

---

## 7. Common failure notes

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Error: HTTP Error: 403 … Cloud Functions API has not been used` | APIs not enabled on first deploy | Accept the CLI prompt, or enable Cloud Functions / Cloud Build / Artifact Registry in the Console; re-deploy |
| Functions deploy fails on Spark plan | Functions need Blaze | Upgrade to Blaze (Console → Usage and billing) |
| `tsc` errors during deploy | TypeScript didn't compile | `cd firebase_functions && npm run build` and fix locally first |
| Node engine warning / deploy refusal | Local Node ≠ 20 | Use Node 20 (matches `engines` in `package.json`) |
| `curl` returns `404 unknown webhook token` | Token missing/wrong, or `webhookToken` not set on `users/{uid}` | Verify the token in the URL matches the user doc's `webhookToken` |
| `curl` returns `400` | Payload violates the contract | Read the `details[]` array; `title` + `message` are required, `status` ∈ {success,error,warning,info}, `url` must be http(s) |
| `201` but no push arrives | No registered device / stale FCM token | Open the app on a real device to register; the function auto-deletes stale tokens — re-open to re-register |
| iOS: no push ever | APNs key not uploaded, or capabilities missing | Upload APNs auth key (Console → Cloud Messaging); enable Push Notifications + Remote notifications in Xcode; test on a physical device |
| `PERMISSION_DENIED` reading inbox in app | Rules not deployed, or query missing an index | `firebase deploy --only firestore`; check Console → Firestore → Indexes for a build-needed index |
| Query fails with "index required" link | Composite index still building or absent | Click the link to create it, or `firebase deploy --only firestore:indexes`; wait for `Enabled` |
| Emulator / `npm run test:rules` won't start | JDK too old | `export JAVA_HOME=$(/usr/libexec/java_home -v 17)` (needs JDK 11+) |
| App can't reach Firebase after `flutterfire configure` | Generated config points at wrong project | Re-run `flutterfire configure` with the correct project selected |

### Useful commands

```bash
firebase use                         # which project am I deploying to?
firebase deploy --only functions:webhook
firebase deploy --only firestore:rules
firebase functions:log --only webhook
firebase emulators:start             # full local stack before deploying
```

---

## 8. Release checklist

- [ ] `firebase use` shows the intended project
- [ ] `flutter analyze` + `flutter test` green
- [ ] `firebase_functions`: `npm run lint`, `npm run build`, `npm test` green
- [ ] `npm run test:rules` green (rules validated against emulator)
- [ ] `firebase deploy --only firestore` (rules + indexes); indexes `Enabled`
- [ ] `firebase deploy --only functions`; note the printed function URL
- [ ] `curl` smoke test → `201`, doc appears in `notifications`
- [ ] Push received on a real device; tap opens detail / `url`
- [ ] App built and (staged) released for Android / iOS
- [ ] Examples updated if the payload contract changed
