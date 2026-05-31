# features/notifications/

The core inbox experience, backed by the Firestore `notifications`
collection (scoped to the signed-in `uid`):

- inbox grouped by day
- categories with status colors (see `shared/notification_status.dart`)
- search
- mark-read / mark-all-read
- tap a notification with a `url` to open it (PR/session/dashboard)

Receiving FCM pushes that surface these notifications is wired here too.
