# features/settings/

Account and app settings. The centerpiece is **`SettingsScreen`**, which shows
the user their personal webhook URL (`POST /webhook/{webhookToken}`) to copy
into their integrations — the product's primary call to action. Reached from the
gear icon in the home AppBar.

## What it does

- Streams `users/{uid}` from Firestore and reads the `webhookToken` minted at
  sign-in by `AuthService.ensureUserDocument`. Streaming (not a one-shot read)
  means a token backfilled just after first sign-in shows up without a refresh.
- Builds the full URL for **this deployment's** Firebase project via
  `WebhookUrlBuilder` and renders it with a copy-to-clipboard button, plus a
  ready-to-run `curl` snippet matching the shared payload contract.

## Configuring the base URL (self-hosting)

NotifyMe is self-hosted, so the webhook base differs per deployment. By default
the URL is derived at runtime — no project ID is hardcoded (see CLAUDE.md):

```
https://<region>-<projectId>.cloudfunctions.net/webhook/<token>
```

`projectId` comes from the generated `firebase_options.dart`
(`Firebase.app().options.projectId`); `region` defaults to `us-central1` (the
region the `webhook` function deploys to when none is set).

Override at build time with `--dart-define`:

| Define | Purpose |
| --- | --- |
| `NOTIFYME_FUNCTIONS_REGION` | Cloud Functions region, if you deployed somewhere other than `us-central1` (e.g. `europe-west1`). |
| `NOTIFYME_WEBHOOK_BASE_URL` | A full base URL (everything before `/<token>`). Use for a Firebase Hosting rewrite or custom domain in front of the function, e.g. `https://hooks.example.com/webhook`. Takes precedence over the region define. |

```bash
# Example: function deployed to europe-west1
flutter run --dart-define=NOTIFYME_FUNCTIONS_REGION=europe-west1

# Example: custom domain / hosting rewrite in front of the function
flutter run --dart-define=NOTIFYME_WEBHOOK_BASE_URL=https://hooks.example.com/webhook
```

See `webhook_url.dart` for the precedence rules and `settings_screen.dart` for
the UI. Sign-out currently lives on the home AppBar.
