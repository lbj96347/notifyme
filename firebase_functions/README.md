# firebase_functions

Cloud Functions for NotifyMe — the webhook receiver and FCM sender.

Exposes `POST /webhook/{userToken}`. The function resolves `userToken` to a
`uid`, writes a notification document to Firestore, looks up that user's device
FCM tokens, and sends the push via FCM. This is the only externally-reachable
surface.

## Webhook handler (`src/webhook.ts`)

`POST /webhook/{userToken}` is wired up and exported as the `webhook` function.
The handler runs in order:

1. **Method gate** — anything but `POST` gets `405` with an `Allow: POST` header.
2. **Token resolution** — the last path segment is extracted (`extractToken`)
   and resolved via `resolveUserToken`. A malformed *or* unknown token returns
   the same `404` (`unknown webhook token`); the two are never distinguished.
3. **Payload validation** — the JSON body is checked against the contract by
   `validatePayload`. Failures return `400` with a `details` array of messages.
4. **Persist** — `createNotification` (`src/notifications.ts`) writes to the
   `notifications` collection with `read: false` and a server-timestamp
   `createdAt`, returning `201 { ok: true, id }`. An unexpected write error
   returns `500 { ok: false, error: "internal error" }`.
5. **Push** — `sendToDevices` (`src/messaging.ts`) delivers the notification to
   the user's devices via FCM. This is **best-effort**: the notification is
   already saved, so a push failure is logged but never changes the `201`.

Responses are always JSON: `{ ok: true, id }` on success, `{ ok: false, error,
details? }` otherwise.

## FCM sender (`src/messaging.ts`)

`sendToDevices(uid, notificationId, payload)` looks up every device the user has
registered in the `devices` collection and pushes to all of them:

- **No devices** (or none with a usable token) → no-op; returns a zeroed result
  without calling FCM.
- Each push carries a display `notification` (`title`/`body`) plus a `data`
  payload — `notificationId`, `title`, `body`, `status`, and `category`/`url`
  when present (all values strings) — so the app can deep-link on tap.
- **Stale-token cleanup** — any token FCM reports as unregistered/invalid
  (`registration-token-not-registered`, `invalid-registration-token`,
  `invalid-argument`) has its device document deleted in a batch.

## Webhook payload contract

```json
{ "title": "...", "message": "...", "category": "claude", "status": "success", "url": "https://..." }
```

`title` + `message` are the notification body (both required). `status` maps to
a color — a closed set of `success` (green), `error` (red), `warning` (yellow),
`info` (blue), defaulting to `info`. `category` organizes the inbox — free-form,
defaulting to `general` when omitted (well-known: `claude`, `codex`, `ci`,
`github-actions`, `n8n`, `bash`, `general`). `url` (`http(s)`) makes the
notification tappable. See `src/validation.ts` for the authoritative rules.

## Webhook token → uid resolution

The `{userToken}` path segment is the **routing key**: it tells the function
which user a notification belongs to. Resolution lives in `src/token.ts`.

**Storage model (MVP).** Each user document carries an extra field:

```
users/{uid} = { uid, email, createdAt, webhookToken }
```

`resolveUserToken(token)` runs a single equality query
(`where("webhookToken", "==", token).limit(1)`) and returns the matching
document's id — which *is* the `uid`, since `users` is keyed by uid — or `null`
when the token is malformed or unowned. Because it's a single-field query,
Firestore serves it from its **automatic** index, so there is no
`firestore.indexes.json` to deploy and a fresh Firebase project works as-is.

**Provisioning.** `generateWebhookToken()` mints a 256-bit url-safe token; the
sign-up flow (or a setup script) writes it to the new user's `webhookToken`
field. `isValidTokenFormat(token)` cheaply rejects malformed path segments
before any query runs — the handler should map both a malformed and an unknown
token to a `404` without revealing which.

**Security posture.** In the MVP the token is an *unguessable routing key*, not
a verified secret — security rests on its entropy. The PRD's v2
`Authorization: Bearer` secret check layers on top of this same lookup and is
intentionally **not** implemented here.

## Tests

- `npm test` — pure unit tests (`src/*.test.ts`) for the handler, validator,
  token resolver and FCM sender. No emulator or credentials required.
- `npm run test:rules` — Firestore **security-rules** tests (`src/*.spec.ts`)
  that exercise the repo-root `firestore.rules` against the Firestore emulator,
  covering ownership-by-`uid` for `users`, `devices` and `notifications` plus
  the server-only `create` constraint on notifications. The command wraps the
  tests in `firebase emulators:exec`, so it needs the Firebase CLI and a
  **Java 11+** JDK on the active path (the emulator refuses older JDKs — on
  macOS, e.g. `export JAVA_HOME=$(/usr/libexec/java_home -v 17)`).
