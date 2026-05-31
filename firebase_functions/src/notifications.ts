/**
 * Notification document writer.
 *
 * Turns a validated webhook payload into a document in the top-level
 * `notifications` collection. The schema is keyed by `uid` so Firestore security
 * rules can scope every read to the authenticated owner:
 *
 *   notifications/{id} = {
 *     uid, title, message, category, status, url?, read, createdAt
 *   }
 *
 * `read` is initialized to `false` (the app flips it on view / mark-all-read).
 * `createdAt` is a server timestamp so ordering is consistent regardless of the
 * caller's clock. Runs with Admin privileges (see `./admin`).
 */
import { FieldValue } from "firebase-admin/firestore";
import { db } from "./admin";
import type { ValidatedPayload } from "./validation";

/** Top-level collection holding one document per notification. */
export const NOTIFICATIONS_COLLECTION = "notifications";

/**
 * Persist a notification for `uid` from a validated payload.
 *
 * `category` is always set (validation defaults a missing one to `general`).
 * The optional `url` is written only when present, so a document never carries
 * an empty-string placeholder. Returns the new doc id.
 */
export async function createNotification(
  uid: string,
  payload: ValidatedPayload,
): Promise<string> {
  const doc: Record<string, unknown> = {
    uid,
    title: payload.title,
    message: payload.message,
    category: payload.category,
    status: payload.status,
    read: false,
    createdAt: FieldValue.serverTimestamp(),
  };
  if (payload.url !== undefined) {
    doc.url = payload.url;
  }

  const ref = await db.collection(NOTIFICATIONS_COLLECTION).add(doc);
  return ref.id;
}
