# features/devices/

Device registration for push delivery. Requests notification permission,
then registers this device's FCM token into the Firestore `devices`
collection (`uid`, `fcmToken`, `platform`, `createdAt`, `updatedAt`) and
keeps it fresh on token refresh, so the Cloud Function can look up where to
send a user's pushes.

`DeviceService.register(uid)` is called from `HomePage` once the user is
signed in. It dedups on `uid + fcmToken` so re-registering the same device
updates `updatedAt` rather than creating duplicates, and subscribes to
`onTokenRefresh` to persist rotated tokens. Declined permission is a no-op
(no token stored) and never blocks the app.
