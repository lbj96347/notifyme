# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Product

NotifyMe is a self-hosted alternative to Pushover/ntfy/Bark: it gives each developer a personal webhook URL that pushes notifications to their phone. The driving use case is monitoring long-running developer/AI-agent jobs (Claude Code, Codex CLI, n8n, GitHub Actions, CI, crawlers) — `POST webhook → phone notification → open app → view details`. Users deploy the open-source stack into **their own Firebase project**, so nothing may hardcode project IDs or depend on a central server.

## Commands

Functions (run from `firebase_functions/`):

- `npm install` — install deps.
- `npm run build` — compile TS `src/` → JS `lib/` (build output; never hand-edit `lib/`).
- `npm run lint` / `npm run lint:fix` — ESLint over `src`.
- `npm test` — builds, then runs `node --test lib/*.test.js`. Single file: `npm run build && node --test lib/webhook.test.js`.
- `npm run test:rules` — Firestore rules tests (`*.spec.ts`) under the emulator.
- `npm run serve` — Functions emulator; `npm run emulators` — all emulators; `npm run deploy` — deploy functions.

Flutter (run from `flutter_app/`):

- `flutter pub get`, `flutter analyze`, `flutter test`, `flutter run`.
- Single test: `flutter test test/<name>_test.dart`. Format: `dart format .`. Filenames are `snake_case.dart`.

Firebase config (`firebase.json`, `firestore.rules`, `firestore.indexes.json`) lives at the repo root.

## Architecture

End-to-end flow is the core of the product:

```
external system → Cloud Function POST /webhook/{userToken} → Firestore (notifications) → FCM push → phone → tap → notification detail
```

### Backend (`firebase_functions/src/`)

`index.ts` is the only externally-reachable surface and exports a single function, `webhook`. Importing `./admin` initializes the Admin SDK exactly once. The webhook handler (`webhook.ts`) pipeline:

1. POST-only (405 otherwise); extract `userToken` from the trailing path segment (`extractToken`).
2. `normalizeWebhookBody` (`statuspage.ts`) — rewrites nested Atlassian Statuspage payloads into the flat contract *before* validation; native flat payloads pass through untouched.
3. `validatePayload` (`validation.ts`) — owns trimming, length limits, and the closed status set (400 on failure).
4. `resolveUserToken` (`token.ts`) — `where("webhookToken", "==", t)` on `users`, served by Firestore's automatic single-field index (no composite index needed — keeps self-hosting friction-free). Unknown/malformed token → 404, **never distinguished** from "token doesn't exist."
5. `createNotification` (`notifications.ts`) — writes the notification doc (201).
6. `sendToDevices` (`messaging.ts`) — best-effort FCM push; failure is logged but never changes the response (the notification is already persisted).

The handler's Firestore/FCM collaborators are injected via a `WebhookDeps` interface so tests use in-memory fakes (no emulator/credentials needed for request-flow tests). `defaultDeps` wires the real ones.

### Frontend (`flutter_app/lib/`)

Feature-first layout: `features/<feature>/` (auth, devices, notifications, bookmarks, settings) holds that feature's services/repositories/screens/models; `shared/` holds cross-feature models (`notification_category.dart`, `notification_status.dart`); `app/` is the shell (`auth_gate.dart`, `home_page.dart`).

- `main.dart` boots Firebase resiliently — it detects `YOUR_`-prefixed placeholder values in `firebase_options.dart` and renders a diagnostic screen instead of crashing. `firebase_options.dart` is **generated and not committed**; `firebase_options.dart.example` is the committed template (run `flutterfire configure`).
- `auth_gate.dart` is stream-driven off `AuthService.authStateChanges()`; on a restored session it re-asserts the user profile (`ensureUserDocument`) to backfill the webhook token.
- `notification_tap_router.dart` wires all three FCM tap entry points (terminated `getInitialMessage`, background `onMessageOpenedApp`, foreground `onMessage` → in-app banner). Navigation uses the root `notificationNavigatorKey` since taps arrive outside the widget tree. Routes by `notificationId`, falling back to opening `url`.
- `notification_repository.dart` owns all Firestore access for `notifications` (paged via `NotificationPage` cursors); UI never references collection/field names.

### Firestore model & rules

Collections keyed by `uid`: `users` (uid, email, createdAt, **webhookToken**; + `users/{uid}/bookmarks` subcollection), `devices` (uid, fcmToken, platform), `notifications` (uid, title, message, category, status, read, bookmarked, createdAt).

Rules (`firestore.rules`) scope every read/write to the authenticated owner's `uid`. Notifications are **created server-side only** (Admin SDK bypasses rules); clients may read, delete, and flip client-owned flags (`read`, `bookmarked`) but the update rule pins `uid` so ownership can't be reassigned. Subcollection rules don't inherit — the `bookmarks` block is explicit.

## Webhook payload contract

```json
{ "title": "...", "message": "...", "category": "claude", "status": "success", "url": "https://..." }
```

`title`+`message` are the body; `status` maps to a color (closed set, green=success/red=error/yellow=warning/blue=info); `category` organizes the inbox; `url` makes the notification tappable. This contract is **shared across the Cloud Function, the Flutter model parsing, docs, and `examples/`** (bash, claude-code, codex-cli, github-actions, n8n) — when it changes, update validation tests, Flutter parsing, and every example in lockstep. License is MIT; `examples/` are a first-class deliverable (the adoption path).

## Scope discipline

`PRD.md` separates MVP from v2. v2-only (do not build into MVP unless asked): notification rules/priority, `Authorization: Bearer` webhook secret verification, multiple projects, and team sharing (one webhook → many recipients). The token is currently an unguessable routing key, **not** a verified secret.
