# NotifyMe

A self-hosted alternative to Pushover / ntfy / Bark. NotifyMe gives every
developer a personal webhook URL that pushes notifications straight to their
phone.

The driving use case is **monitoring long-running developer and AI-agent jobs**
— Claude Code, Codex CLI, n8n, GitHub Actions, CI pipelines, crawlers. The flow
is dead simple:

```
POST webhook → phone notification → open app → view details
```

You deploy the entire open-source stack into **your own Firebase project**.
There is no central server, no hardcoded project IDs, and no third party in the
path — your notifications stay yours.

## MVP scope

The MVP delivers the end-to-end path from a webhook to a notification on your
phone:

- **Personal webhook URL** — `POST /webhook/{userToken}` accepts a notification
  payload and routes it to your device.
- **Push delivery** — notifications arrive via Firebase Cloud Messaging (FCM).
- **Notification inbox** — grouped by day, with categories and status colors
  (green = success, red = error, yellow = warning, blue = info).
- **Search** across your notifications.
- **Read state** — mark a notification read, or mark all read.
- **Tappable notifications** — an optional `url` opens the relevant PR, session,
  or dashboard.

Out of scope for the MVP (planned for v2): notification rules and priority,
`Authorization: Bearer` webhook secret verification, multiple projects, and team
sharing (one webhook fanning out to many recipients).

## Architecture

NotifyMe is a Flutter client backed entirely by Firebase. The end-to-end flow is
the core of the product:

```
external system
  → Cloud Function (POST /webhook/{userToken})
    → Firestore (notifications)
      → FCM push
        → phone
          → open app
            → notification detail
```

Three pieces and how they connect:

- **Cloud Functions** (`firebase_functions/`) — the only externally-reachable
  surface. The function resolves `userToken` to a `uid`, writes a notification
  document to Firestore, looks up that user's device FCM tokens, and sends the
  push via FCM.
- **Firestore** — three top-level collections, all keyed by `uid`:
  - `users` — `uid`, `email`, `createdAt`
  - `devices` — `uid`, `fcmToken`, `platform`
  - `notifications` — `uid`, `title`, `message`, `category`, `status`, `read`,
    `createdAt`

  Security rules scope every read and write to the authenticated user's own
  `uid`.
- **Flutter app** (`flutter_app/`) — uses Firebase Auth (sign-in), Firestore
  (inbox / search / read state), Firebase Messaging (registers the device FCM
  token into `devices` and receives pushes), and Analytics.

### Webhook payload contract

This contract is shared across the Cloud Function, the Flutter app, and the
examples. Keep all three in sync when it changes.

```json
{ "title": "...", "message": "...", "category": "claude", "status": "success", "url": "https://..." }
```

- `title` + `message` — the notification body.
- `status` — maps to a color (`success`, `error`, `warning`, `info`).
- `category` — organizes the inbox.
- `url` — optional; makes the notification tappable to open a PR, session, or
  dashboard.

## Repository layout

```
notifyme/
├── flutter_app/          # Flutter iOS/Android client
├── firebase_functions/   # Cloud Functions (webhook receiver + FCM sender)
├── docs/
└── examples/             # Copy-paste webhook senders:
    ├── claude-code/
    ├── codex-cli/
    ├── n8n/
    ├── github-actions/
    └── bash/
```

The `examples/` are a first-class deliverable — they're the project's adoption
path. Any change to the payload contract must be reflected in their `curl`
snippets.

## Quick start

> NotifyMe is **pre-implementation** — the components below describe the target
> deployment flow once the stack is built.

NotifyMe runs in your own Firebase project. At a high level:

1. **Create a Firebase project** and enable Authentication, Firestore, Cloud
   Functions, and Cloud Messaging.
2. **Deploy the Cloud Function and security rules** from `firebase_functions/`.
   This publishes your personal `POST /webhook/{userToken}` endpoint.
3. **Build and install the Flutter app** from `flutter_app/`, pointing it at
   your Firebase project. Sign in to register your device for push delivery.
4. **Send a notification** from any tool using the payload contract above — see
   `examples/` for copy-paste senders for Claude Code, Codex CLI, n8n, GitHub
   Actions, and plain `curl`.

A minimal send looks like:

```bash
curl -X POST "https://<your-region>-<your-project>.cloudfunctions.net/webhook/<userToken>" \
  -H "Content-Type: application/json" \
  -d '{ "title": "Build finished", "message": "All tests passed", "category": "ci", "status": "success", "url": "https://github.com/you/repo/actions" }'
```

## License

MIT — see [LICENSE](LICENSE).
