# features/auth/

Firebase Auth sign-in / sign-out and the current-user session.

On first sign-in the user's `uid` is what every Firestore document
(`users`, `devices`, `notifications`) is keyed by, so this feature is the
source of truth for "who am I" that the other features depend on.
