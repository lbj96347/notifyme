# flutter_app

Flutter iOS/Android client for NotifyMe.

Uses Firebase Auth (sign-in), Firestore (inbox / search / read state), Firebase
Messaging (registers the device FCM token into `devices`, receives pushes), and
Analytics.

Features: notification inbox grouped by day, categories with status colors
(green=success, red=error, yellow=warning, blue=info), search, and
mark-read / mark-all-read.

> Not yet implemented — placeholder scaffold.
