# Firestore Schema

This document describes NotifyMe's Firestore data model: the three top-level
collections, their fields, example documents, the indexes that back the app's
queries, and the security model that scopes every document to its owner.

> NotifyMe is self-hosted into the deployer's **own** Firebase project, so this
> schema carries no project IDs and assumes nothing beyond stock Firebase Auth,
> Firestore, Cloud Functions, and FCM.

## Overview

```
external system → Cloud Function (webhook/{userToken}) → Firestore → FCM push → phone
```

All three collections are top-level (not subcollections) and **keyed by `uid`** —
the Firebase Auth user ID. Ownership is expressed as a `uid` field on every
document, and the security rules gate every read/write on
`request.auth.uid == <doc>.uid`. There is no central server and no shared data:
a user only ever sees documents carrying their own `uid`.

| Collection      | Document ID            | Written by            | Read by        |
| --------------- | ---------------------- | --------------------- | -------------- |
| `users`         | `uid`                  | App (own profile)     | App (owner)    |
| `devices`       | auto-ID (`deviceId`)   | App (own device)      | App + Function |
| `notifications` | auto-ID                | **Function only**     | App (owner)    |

---

## `users`

One profile document per account. The document ID **is** the `uid`, so a user's
own profile is a direct lookup (`users/{uid}`) with no query needed.

| Field          | Type      | Notes                                                            |
| -------------- | --------- | ---------------------------------------------------------------- |
| `uid`          | string    | Firebase Auth UID. Matches the document ID.                      |
| `email`        | string    | Account email from Firebase Auth.                                |
| `createdAt`    | timestamp | Server timestamp set on first sign-in.                           |
| `webhookToken` | string    | Unguessable routing key for `POST /webhook/{userToken}`. Minted on first sign-in. |

The app provisions this document on the **first successful sign-in** (see
`AuthService.ensureUserDocument`): it writes `uid`/`email`/`createdAt` and mints
a 256-bit url-safe `webhookToken` (`Random.secure`, base64url, no padding) only
when one isn't already present, so a user's webhook URL stays stable. The webhook
Cloud Function resolves an incoming `userToken` back to a `uid` with a single
`where("webhookToken", "==", token)` query (`firebase_functions/src/token.ts`).

### Example

```json
// users/Lp9aQ2... (doc ID == uid)
{
  "uid": "Lp9aQ2xKfZb3mNvT8sRcWdYe1Hg2",
  "email": "dev@example.com",
  "createdAt": "2026-05-30T14:02:11Z",
  "webhookToken": "k3v8r1Zq...43-char-url-safe-token"
}
```

---

## `devices`

Registered FCM device tokens. The Flutter app writes one document per device on
launch (and refreshes it when FCM rotates the token). The Cloud Function reads
this collection to find every device it must push to for a given `uid`.

| Field       | Type      | Notes                                                          |
| ----------- | --------- | -------------------------------------------------------------- |
| `uid`       | string    | Owner's Firebase Auth UID.                                     |
| `fcmToken`  | string    | FCM registration token for this device.                        |
| `platform`  | string    | `ios` \| `android` (extendable, e.g. `web`).                   |
| `createdAt` | timestamp | Server timestamp set when the device first registers.          |
| `updatedAt` | timestamp | Server timestamp refreshed on every (re)register / token roll. |

Document IDs are auto-generated. Use the `uid + fcmToken` index to upsert/dedup
a token rather than blindly creating duplicates when the same device re-registers.

### Example

```json
// devices/8sKd0Qa... (auto-ID)
{
  "uid": "Lp9aQ2xKfZb3mNvT8sRcWdYe1Hg2",
  "fcmToken": "fGq...:APA91bH...long-token...",
  "platform": "ios",
  "createdAt": "2026-05-30T14:02:11Z",
  "updatedAt": "2026-05-30T14:02:11Z"
}
```

---

## `notifications`

The inbox. Each document is one notification. **These are created server-side
only** — the webhook Cloud Function writes them via the Admin SDK after resolving
`userToken → uid`. Clients can never create or forge a notification (see Security
below); they read their own, flip read state, and delete.

| Field       | Type      | Notes                                                                 |
| ----------- | --------- | --------------------------------------------------------------------- |
| `uid`       | string    | Owner's Firebase Auth UID (resolved from the webhook `userToken`).    |
| `title`     | string    | Notification headline. From the webhook payload.                      |
| `message`   | string    | Notification body. From the webhook payload.                          |
| `category`  | string    | Organizes the inbox. Free-form; defaults to `general`. From payload.  |
| `status`    | string    | `success` \| `error` \| `warning` \| `info`. Maps to a color.         |
| `url`       | string?   | Optional deep link; makes the notification tappable. From payload.    |
| `read`      | boolean   | Read state. App sets `true` on open / mark-all-read.                  |
| `createdAt` | timestamp | Server timestamp set by the function at write time. Sort key.         |

`status` color mapping (shared with the app): green = `success`, red = `error`,
yellow = `warning`, blue = `info`. The status set is **closed** — the webhook
rejects any other value and the app falls back to `info` for an unknown one.

`category` is **free-form** — any short label is accepted so a deployer can
organize their inbox however they like. A missing/blank category is normalized
to `general` by the webhook, so the field is always present. The documented
well-known categories (shipped by `examples/`) are: `claude`, `codex`, `ci`,
`github-actions`, `n8n`, `bash`, and `general`.

### Webhook payload → document

The webhook payload contract (shared across the function, the app, and
`examples/`) maps directly onto the document; the function adds the
server-controlled fields:

```json
// incoming POST /webhook/{userToken}
{ "title": "Build passed", "message": "main is green", "category": "ci", "status": "success", "url": "https://github.com/acme/app/actions/runs/42" }
```

```json
// notifications/3kZpQ1... (written by the function)
{
  "uid": "Lp9aQ2xKfZb3mNvT8sRcWdYe1Hg2",
  "title": "Build passed",
  "message": "main is green",
  "category": "ci",
  "status": "success",
  "url": "https://github.com/acme/app/actions/runs/42",
  "read": false,
  "createdAt": "2026-05-30T14:07:53Z"
}
```

---

## Required indexes

Defined in `firestore.indexes.json` at the repo root. Composite indexes back the
app's filtered/sorted queries; Firestore serves single-field equality and the
default ID lookups automatically.

| Collection      | Index fields                          | Backs                                      |
| --------------- | ------------------------------------- | ------------------------------------------ |
| `notifications` | `uid ASC, createdAt DESC`             | Inbox, newest-first (grouped by day).      |
| `notifications` | `uid ASC, category ASC, createdAt DESC` | Category filter within the inbox.        |
| `notifications` | `uid ASC, read ASC, createdAt DESC`   | Unread filter / unread badge.              |
| `devices`       | `uid ASC, fcmToken ASC`               | Token lookup + dedup on re-registration.   |

`users` needs no composite index — it is always accessed by document ID (`uid`).

> Search: free-text search over `title`/`message` is **not** a Firestore index.
> Firestore has no full-text search; the app filters client-side over the already
> loaded inbox, or a deployer wires an external search service. Do not assume a
> server-side text query exists.

Deploy indexes with `firebase deploy --only firestore:indexes`.

---

## Security model

Rules live in `firestore.rules` (repo root). The core invariant: **a request may
only touch documents whose `uid` equals the caller's authenticated UID.** A single
helper expresses it:

```
function isOwner(uid) {
  return request.auth != null && request.auth.uid == uid;
}
```

### Per-collection rules

- **`users/{uid}`** — `allow read, write: if isOwner(uid)`. The document ID is the
  UID, so ownership is checked against the path itself. A user reads and writes
  only their own profile.

- **`devices/{deviceId}`** — owner-scoped via the document's `uid` field:
  - `read, delete` require `isOwner(resource.data.uid)` (the existing doc's owner).
  - `create` requires `isOwner(request.resource.data.uid)` — you can only create a
    device that carries your own `uid`.
  - `update` requires ownership of **both** the old and new doc, so a device can't
    be reassigned to another user.

- **`notifications/{notificationId}`** — read + constrained writes, never client creates:
  - `read, delete` require `isOwner(resource.data.uid)`.
  - `update` requires owning the doc before and after, and pins `uid` immutable
    (`request.resource.data.uid == resource.data.uid`) — the app flips `read`, it
    can't rewrite ownership.
  - `create: if false` — **all creates are denied.** Notifications are written only
    by the Cloud Function through the Admin SDK, which bypasses these rules. This
    is what stops a signed-in client from forging inbox entries.

### How `uid` ownership works end-to-end

1. **Auth** establishes `request.auth.uid` for every client request. No auth → no
   access (all rules fail the `request.auth != null` check).
2. **Every document stores its owner's `uid`** (and for `users`, the doc ID is the
   uid). Rules compare that stored `uid` to `request.auth.uid`.
3. **Queries must constrain `uid`.** Because rules don't filter result sets, the
   app always queries `where('uid', '==', currentUid)`; the composite indexes above
   all lead with `uid` to serve exactly those queries. A query that omits `uid`
   would be rejected by the rules (the matched docs fail `isOwner`).
4. **The webhook bridges an unauthenticated caller to a `uid`.** External systems
   POST with a `userToken`, not Firebase Auth. The Cloud Function resolves
   `userToken → uid`, then writes the notification with that `uid` using the Admin
   SDK. The token is the routing key (and, in v2, the `Authorization: Bearer`
   secret); rules are intentionally bypassed on this path, which is why client
   creates are forbidden.

### Assumptions

- Firebase Auth is the sole identity source; `request.auth.uid` is trusted.
- The Cloud Function uses the Admin SDK (rules do not apply to it) and is the
  **only** writer of `notifications`.
- The webhook endpoint is the only externally reachable surface; treat `userToken`
  as a secret-grade routing key.
- No cross-user reads exist by design — there are no shared documents and no
  collection-group queries spanning users. (Team sharing is explicitly v2.)
