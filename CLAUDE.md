# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

This repository is **pre-implementation**. The only file is `PRD.md`; there is no source code, build tooling, dependency manifests, tests, or git history yet. Do not assume commands like `flutter run` or `firebase deploy` are wired up — the projects they target don't exist. When scaffolding, create the structure described below rather than guessing at an existing layout.

## Product

NotifyMe is a self-hosted alternative to Pushover/ntfy/Bark: it gives each developer a personal webhook URL that pushes notifications to their phone. The driving use case is monitoring long-running developer/AI-agent jobs (Claude Code, Codex CLI, n8n, GitHub Actions, CI, crawlers) — `POST webhook → phone notification → open app → view details`. Users deploy the open-source stack into **their own Firebase project**, so the design must stay self-host-friendly (no hardcoded project IDs, no central server dependency).

## Architecture (planned, per PRD.md)

The system is a Flutter client backed entirely by Firebase. The end-to-end flow is the core of the product:

```
external system → Cloud Function (webhook/{userToken}) → Firestore (notifications) → FCM push → phone → open app → notification detail
```

Three pieces and how they connect:

- **`firebase_functions/`** — A Cloud Function exposes `POST /webhook/{userToken}`. It resolves `userToken` to a `uid`, writes a notification document to Firestore, looks up that user's device FCM tokens, and sends the push via FCM. This is the only externally-reachable surface; treat the `userToken` as the routing key (and, in v2, the auth secret via `Authorization: Bearer`).
- **Firestore** — Three top-level collections, all keyed by `uid`: `users` (uid, email, createdAt), `devices` (uid, fcmToken, platform), `notifications` (uid, title, message, category, status, read, bookmarked, createdAt). Security rules must scope every read/write to the authenticated user's own `uid`.
- **`flutter_app/`** — Uses Firebase Auth (sign-in), Firestore (inbox/search/read state), Firebase Messaging (registers the device FCM token into `devices`, receives pushes), and Analytics. Features: notification inbox grouped by day, categories with status colors (green=success, red=error, yellow=warning, blue=info), search, and mark-read / mark-all-read.

### Webhook payload contract

This contract is shared across the function, the Flutter app, and the `examples/`. Keep all three in sync when it changes.

```json
{ "title": "...", "message": "...", "category": "claude", "status": "success", "url": "https://..." }
```

`title` + `message` are the notification body. `status` maps to a color. `category` organizes the inbox. `url` (PRD-recommended enhancement) makes the notification tappable to open a PR/session/dashboard — wire it into the FCM payload and the app's tap handler.

## Repository layout (target)

```
notifyme/
├── flutter_app/          # Flutter iOS/Android client
├── firebase_functions/   # Cloud Functions (webhook receiver + FCM sender)
├── docs/
└── examples/             # Copy-paste webhook senders: claude-code/, codex-cli/, n8n/, github-actions/, bash/
```

License is MIT. The `examples/` are a first-class deliverable (the project's adoption path), so any payload change must be reflected in the example `curl` snippets.

## Scope discipline

`PRD.md` separates MVP from v2. v2-only (do not build into MVP unless asked): notification rules/priority, `Bearer` webhook secret verification, multiple projects, and team sharing (one webhook → many recipients).
