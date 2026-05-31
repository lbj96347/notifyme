/**
 * Firebase Admin SDK initialization.
 *
 * Initialized once here and shared across functions so we don't re-init the app
 * on every cold start. The Admin SDK runs with full privileges and bypasses
 * Firestore security rules — that is what lets the webhook resolve an
 * unauthenticated `userToken` to a `uid` and write notifications on the user's
 * behalf.
 *
 * In Cloud Functions and the Firebase emulators, `initializeApp()` picks up
 * project credentials from the environment automatically — no service-account
 * key or hardcoded project ID, keeping the stack self-host-friendly.
 */
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";

// Guard against double-initialization (e.g. during hot reloads in the shell).
const app = getApps().length ? getApps()[0] : initializeApp();

export const db = getFirestore(app);
export const messaging = getMessaging(app);
