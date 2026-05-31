# Running & Testing the Webhook in the Firebase Emulators

This guide runs the NotifyMe Cloud Functions locally in the **Firebase Local
Emulator Suite**, seeds a test user + device, and fires `POST /webhook/{userToken}`
with `curl` — no real Firebase project, billing, or phone required.

Everything below talks to local emulators only. Nothing here touches a
production project, sends a real FCM push, or costs money.

> **The webhook flow** (see `firebase_functions/src/webhook.ts`):
> `POST /webhook/{userToken}` → resolve token to `uid` → validate body →
> write a `notifications` document → best-effort FCM push to the user's devices.
> In the emulator the Firestore write is real (you'll see the document in the
> Emulator UI); the FCM push is best-effort and does **not** affect the HTTP
> response, so a missing/fake device token never changes the result.

---

## 0. Prerequisites

| Tool | Why | Check |
|------|-----|-------|
| [Node.js](https://nodejs.org) 18+ (20 recommended) | Functions runtime + build | `node -v` |
| [Firebase CLI](https://firebase.google.com/docs/cli) | runs the emulators | `firebase --version` |
| Java JDK 11+ | required by the Firestore emulator | `java -version` |
| `curl` | fire test webhooks | `curl --version` |

Install dependencies once:

```bash
cd firebase_functions
npm install
```

The emulator config already lives in `firebase.json` at the repo root:

```jsonc
"emulators": {
  "auth":      { "port": 9099 },
  "functions": { "port": 5001 },
  "firestore": { "port": 8080 },
  "ui":        { "enabled": true },
  "singleProjectMode": true
}
```

---

## 1. Start the emulators

Because the stack is self-host-friendly (no hardcoded project ID), you pass a
**throwaway project ID** on the command line. Prefixing it with `demo-` tells
the CLI this is a demo project that never connects to real Google Cloud — ideal
for local testing.

From the repo root:

```bash
# Build the TypeScript, then start every emulator under a demo project.
cd firebase_functions && npm run build && cd ..
firebase emulators:start --project demo-notifyme
```

Or use the package script (builds + starts all emulators), then add the project flag:

```bash
cd firebase_functions
npm run emulators -- --project demo-notifyme
```

You should see something like:

```
✔  functions: Loaded functions definitions from source: webhook.
✔  functions[us-central1-webhook]: http function initialized
   (http://127.0.0.1:5001/demo-notifyme/us-central1/webhook).
┌────────────────┬────────────────┬──────────────────────────────────┐
│ Emulator       │ Host:Port      │ View in Emulator UI              │
├────────────────┼────────────────┼──────────────────────────────────┤
│ Authentication │ 127.0.0.1:9099 │ http://127.0.0.1:4000/auth       │
│ Firestore      │ 127.0.0.1:8080 │ http://127.0.0.1:4000/firestore  │
│ Functions      │ 127.0.0.1:5001 │ http://127.0.0.1:4000/functions  │
└────────────────┴────────────────┴──────────────────────────────────┘
```

**Keep this terminal running.** Open the **Emulator UI** at
<http://127.0.0.1:4000> to watch Firestore documents and function logs live.

### The webhook URL

A v2 `onRequest` function in the emulator is served at:

```
http://127.0.0.1:5001/<projectId>/<region>/<functionName>/<userToken>
```

For this guide that's:

```
http://127.0.0.1:5001/demo-notifyme/us-central1/webhook/<userToken>
```

`us-central1` is the default region (the function sets none). The handler reads
`<userToken>` as the **last path segment**, so the trailing `/webhook/<token>`
is what matters.

---

## 2. Seed a test user (and optional device)

The webhook resolves `userToken` by querying `users` for a document whose
`webhookToken` field equals the token (`firebase_functions/src/token.ts`). A
fresh emulator has no data, so you must create one user document first.

**Token rules** (enforced before any Firestore query): 16–256 characters,
`A-Za-z0-9_-` only. We'll use `test-token-abc123456789` throughout.

You can seed either through the UI or with a tiny script.

### Option A — Emulator UI (no code)

1. Open <http://127.0.0.1:4000/firestore>.
2. **Start collection** → `users` → **Document ID** `test-uid-1`
   (the doc ID *is* the `uid`; the `users` collection is keyed by `uid`).
3. Add fields:
   | Field | Type | Value |
   |-------|------|-------|
   | `uid` | string | `test-uid-1` |
   | `email` | string | `tester@example.com` |
   | `webhookToken` | string | `test-token-abc123456789` |
4. *(Optional, only needed to exercise the FCM push path)* Start a `devices`
   collection → auto-ID document with: `uid` = `test-uid-1`, `platform` =
   `android`, `fcmToken` = `fake-token-for-emulator`. In the emulator the push
   is best-effort and the token is fake, so the send is logged/attempted but the
   HTTP response stays `201` regardless.

### Option B — Seed script (repeatable)

Create `firebase_functions/seed.js` (the Admin SDK auto-targets the emulators
when `FIRESTORE_EMULATOR_HOST` is set — no credentials needed):

```js
// Usage: FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 \
//        GOOGLE_CLOUD_PROJECT=demo-notifyme node seed.js
const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");

initializeApp({ projectId: process.env.GOOGLE_CLOUD_PROJECT || "demo-notifyme" });
const db = getFirestore();

const uid = "test-uid-1";
const token = "test-token-abc123456789";

(async () => {
  await db.collection("users").doc(uid).set({
    uid,
    email: "tester@example.com",
    webhookToken: token,
  });
  // Optional: a device so the FCM push path runs (token is fake → push no-ops).
  await db.collection("devices").add({
    uid,
    platform: "android",
    fcmToken: "fake-token-for-emulator",
  });
  console.log(`Seeded user ${uid} with webhookToken ${token}`);
  process.exit(0);
})();
```

Run it against the live emulators (from `firebase_functions/`):

```bash
FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 \
GOOGLE_CLOUD_PROJECT=demo-notifyme \
node seed.js
```

> Emulator data is in-memory and cleared on restart. To persist it across runs,
> start with `firebase emulators:start --project demo-notifyme --export-on-exit ./emulator-data --import ./emulator-data`.

---

## 3. Fire a test webhook with curl

Set the URL once for convenience:

```bash
WEBHOOK="http://127.0.0.1:5001/demo-notifyme/us-central1/webhook/test-token-abc123456789"
```

### Success — full payload

```bash
curl -i -X POST "$WEBHOOK" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Build finished",
    "message": "Claude Code finished the refactor in 4m12s.",
    "category": "claude",
    "status": "success",
    "url": "https://github.com/you/repo/pull/42"
  }'
```

**Expected — `201 Created`:**

```json
{ "ok": true, "id": "<generated-doc-id>" }
```

A new document appears under `notifications` in the Emulator UI with your
fields plus `uid`, `read: false`, and a server-set `createdAt`. The Functions
log shows a `pushed notification` line (best-effort FCM).

### Success — minimal payload

Only `title` and `message` are required; `status` defaults to `info`.

```bash
curl -i -X POST "$WEBHOOK" \
  -H "Content-Type: application/json" \
  -d '{ "title": "Heartbeat", "message": "still alive" }'
```

→ `201 Created`, `{ "ok": true, "id": "..." }`. The stored document has
`status: "info"` and no `category`/`url`.

---

## 4. Error responses

The handler checks method → token → body, in that order. Each stage below is
reproducible against the running emulator.

### 404 — unknown or malformed token

A token that no user owns, **or** one that fails the format check, returns the
same 404 (the two are deliberately not distinguished, so the endpoint never
confirms whether a token exists).

```bash
# Well-formed but not seeded:
curl -i -X POST "http://127.0.0.1:5001/demo-notifyme/us-central1/webhook/nonexistent-token-9999" \
  -H "Content-Type: application/json" \
  -d '{ "title": "x", "message": "y" }'

# Malformed (too short / illegal chars) — same 404:
curl -i -X POST "http://127.0.0.1:5001/demo-notifyme/us-central1/webhook/short" \
  -H "Content-Type: application/json" \
  -d '{ "title": "x", "message": "y" }'
```

**Expected — `404 Not Found`:**

```json
{ "ok": false, "error": "unknown webhook token" }
```

### 400 — invalid payload

Missing/empty required fields, a bad `status`, a non-`http(s)` `url`, or
over-length fields. Errors are collected and returned together.

```bash
# Missing both required fields:
curl -i -X POST "$WEBHOOK" \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Expected — `400 Bad Request`:**

```json
{
  "ok": false,
  "error": "invalid payload",
  "details": [
    "title is required and must be a string",
    "message is required and must be a string"
  ]
}
```

More 400 examples:

```bash
# Invalid status (must be success | error | warning | info):
curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json" \
  -d '{ "title": "t", "message": "m", "status": "bogus" }'
# → details: ["status must be one of: success, error, warning, info"]

# Non-http(s) url:
curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json" \
  -d '{ "title": "t", "message": "m", "url": "ftp://x" }'
# → details: ["url must be a valid http(s) URL"]

# Body isn't a JSON object:
curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json" \
  -d '"just a string"'
# → details: ["body must be a JSON object"]
```

### 405 — wrong method

Anything other than `POST`. The response also sets an `Allow: POST` header.

```bash
curl -i "$WEBHOOK"          # GET
```

**Expected — `405 Method Not Allowed`:**

```json
{ "ok": false, "error": "method not allowed; use POST" }
```

### 500 — internal error

Only emitted if the Firestore **write** itself fails (e.g. the Firestore
emulator isn't running). Not reproducible under a healthy emulator; shown here
for completeness:

```json
{ "ok": false, "error": "internal error" }
```

---

## 5. Response reference

| Status | When | Body |
|--------|------|------|
| `201 Created` | Notification persisted (push is best-effort) | `{ "ok": true, "id": "<doc-id>" }` |
| `400 Bad Request` | Body fails the payload contract | `{ "ok": false, "error": "invalid payload", "details": [...] }` |
| `404 Not Found` | Token unknown **or** malformed (indistinguishable) | `{ "ok": false, "error": "unknown webhook token" }` |
| `405 Method Not Allowed` | Method isn't `POST` (`Allow: POST` header set) | `{ "ok": false, "error": "method not allowed; use POST" }` |
| `500 Internal Server Error` | Firestore write failed | `{ "ok": false, "error": "internal error" }` |

---

## 6. Troubleshooting

| Symptom | Fix |
|---------|-----|
| `404` on a token you seeded | Confirm the `users` doc has a `webhookToken` field **exactly** equal to the URL's last segment, and that the token is 16–256 chars of `A-Za-z0-9_-`. |
| Function not listed on start | Run `npm run build` in `firebase_functions/` first — the emulator loads from `lib/` (compiled JS), not `src/`. |
| `Port 8080/5001 already in use` | Stop the other process or change the port in `firebase.json` (and update the curl URL accordingly). |
| Firestore emulator won't start | Install a JDK 11+ (`java -version`). |
| Changes to `src/` not reflected | Rebuild (`npm run build`) or run `npm run build:watch` in a second terminal; the Functions emulator hot-reloads `lib/`. |
| Seeded data gone after restart | Emulator state is in-memory — use `--export-on-exit` / `--import` (see §2) to persist. |

---

## Related

- `docs/FIREBASE_SETUP.md` — deploying the real stack to your own project.
- `docs/FIRESTORE_SCHEMA.md` — the `users` / `devices` / `notifications` schema.
- `firebase_functions/src/webhook.ts` — the handler this guide exercises.
- The webhook payload contract is shared with the Flutter app and `examples/` —
  keep all three in sync when it changes.
