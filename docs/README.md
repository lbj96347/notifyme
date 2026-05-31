# docs

Documentation for NotifyMe — setup guides, architecture notes, and self-hosting
instructions for deploying the stack into your own Firebase project.

## Guides

- [FIREBASE_SETUP.md](FIREBASE_SETUP.md) — end-to-end setup: create a Firebase
  project, enable services, register iOS/Android apps, configure FlutterFire,
  deploy rules/functions, and test the webhook.
- [DEPLOYMENT.md](DEPLOYMENT.md) — operational runbook for every release:
  configure Firebase, build the Flutter apps, deploy Firestore rules/indexes and
  the webhook function, verify delivery, and roll back. Includes a release
  checklist and common-failure table.
- [MVP_ACCEPTANCE_CHECKLIST.md](MVP_ACCEPTANCE_CHECKLIST.md) — end-to-end
  acceptance checks for the MVP: sign in, create/copy a webhook token, send a
  webhook, verify the Firestore write and FCM push, then exercise the inbox
  (detail, search, mark read, mark all read). Each step pairs an action with the
  observable result that proves it passed.
