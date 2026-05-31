/**
 * NotifyMe Cloud Functions — entry point.
 *
 * This is the only externally-reachable surface of the stack. The webhook
 * receiver (`POST /webhook/{userToken}`) will resolve `userToken` to a `uid`,
 * write a notification document to Firestore, look up that user's device FCM
 * tokens, and send the push via FCM.
 *
 * Webhook payload contract (kept in sync with the Flutter app and examples/):
 *   { "title": "...", "message": "...", "category": "claude",
 *     "status": "success", "url": "https://..." }
 *
 * Importing `./admin` initializes the Firebase Admin SDK exactly once for every
 * function exported from this file.
 */
import "./admin";

// The webhook receiver: POST /webhook/{userToken} → Firestore notification.
export { webhook } from "./webhook";
