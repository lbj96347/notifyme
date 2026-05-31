/**
 * FCM push sender.
 *
 * Layers on top of the persisted notification (see `./notifications`): given the
 * resolved `uid` and the new notification's id, it finds every device that user
 * has registered and pushes the notification to all of them via FCM.
 *
 *   external system → webhook → Firestore (notifications) → THIS module → phone
 *
 * Devices live in the top-level `devices` collection, one document per device:
 *
 *   devices/{deviceId} = { uid, fcmToken, platform }
 *
 * Each push carries:
 *   - a `notification` block (`title`/`body`) so the OS renders a banner even
 *     when the app is backgrounded; and
 *   - a `data` block (`notificationId`, `title`, `body`, `status`, and
 *     `category`/`url` when present) so the app can deep-link into the detail
 *     view (or open `url`) on tap. All `data` values must be strings.
 *
 * FCM rotates and expires tokens. When a send reports a token as unregistered or
 * invalid, the owning device document is deleted so we stop pushing to a dead
 * token. Runs with Admin privileges (see `./admin`).
 */
import type { MulticastMessage, SendResponse } from "firebase-admin/messaging";
import { db, messaging } from "./admin";
import type { ValidatedPayload } from "./validation";

/** Top-level collection holding one document per registered device. */
export const DEVICES_COLLECTION = "devices";

/** Field on a device document holding its FCM registration token. */
export const FCM_TOKEN_FIELD = "fcmToken";

/**
 * FCM error codes that mean a token will never deliver again, so its device
 * document should be pruned. Everything else (e.g. `messaging/internal-error`,
 * `messaging/server-unavailable`) is treated as transient and left alone.
 *
 * See https://firebase.google.com/docs/cloud-messaging/manage-tokens
 */
const UNREGISTERED_ERROR_CODES = new Set<string>([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
  "messaging/invalid-argument",
]);

/** Summary of a push attempt, returned for logging. */
export interface SendResult {
  /** Device tokens we attempted to deliver to. */
  attempted: number;
  /** Successful deliveries reported by FCM. */
  sent: number;
  /** Failed deliveries reported by FCM. */
  failed: number;
  /** Stale device documents pruned as a result. */
  removed: number;
}

/**
 * Build the FCM `data` payload. Every value must be a string. `category` is
 * always present (validation defaults it to `general`); the optional `url` is
 * included only when present (never as an empty string or `undefined`).
 */
export function buildDataPayload(
  notificationId: string,
  payload: ValidatedPayload,
): Record<string, string> {
  const data: Record<string, string> = {
    notificationId,
    title: payload.title,
    body: payload.message,
    status: payload.status,
    category: payload.category,
  };
  if (payload.url !== undefined) {
    data.url = payload.url;
  }
  return data;
}

/**
 * Assemble a multicast message: a display `notification` plus the `data` payload
 * the app reads on tap.
 */
export function buildMulticastMessage(
  tokens: string[],
  notificationId: string,
  payload: ValidatedPayload,
): MulticastMessage {
  return {
    tokens,
    notification: {
      title: payload.title,
      body: payload.message,
    },
    data: buildDataPayload(notificationId, payload),
  };
}

/**
 * From per-token send responses (index-aligned with the tokens we sent), return
 * the indexes whose failure means the token is permanently invalid and should
 * be pruned.
 */
export function unregisteredTokenIndexes(responses: SendResponse[]): number[] {
  const indexes: number[] = [];
  responses.forEach((response, index) => {
    if (
      !response.success &&
      response.error !== undefined &&
      UNREGISTERED_ERROR_CODES.has(response.error.code)
    ) {
      indexes.push(index);
    }
  });
  return indexes;
}

/**
 * Push a persisted notification to all of `uid`'s registered devices.
 *
 * Returns a summary (and never throws on a delivery problem — callers treat the
 * push as best-effort, since the notification is already saved). Specifically:
 *
 *   - With no registered devices (or none carrying a usable token), it no-ops
 *     and returns a zeroed result without calling FCM.
 *   - After sending, any device whose token FCM reports as unregistered/invalid
 *     is deleted from the `devices` collection in a single batch.
 */
export async function sendToDevices(
  uid: string,
  notificationId: string,
  payload: ValidatedPayload,
): Promise<SendResult> {
  const snapshot = await db
    .collection(DEVICES_COLLECTION)
    .where("uid", "==", uid)
    .get();

  // One target per device document, so a stale token maps back to the exact doc
  // to delete. Skip documents missing a usable token.
  const targets: { token: string; ref: FirebaseFirestore.DocumentReference }[] =
    [];
  for (const doc of snapshot.docs) {
    const token = doc.get(FCM_TOKEN_FIELD);
    if (typeof token === "string" && token.length > 0) {
      targets.push({ token, ref: doc.ref });
    }
  }

  if (targets.length === 0) {
    return { attempted: 0, sent: 0, failed: 0, removed: 0 };
  }

  const tokens = targets.map((t) => t.token);
  const response = await messaging.sendEachForMulticast(
    buildMulticastMessage(tokens, notificationId, payload),
  );

  const stale = unregisteredTokenIndexes(response.responses);
  let removed = 0;
  if (stale.length > 0) {
    const batch = db.batch();
    for (const index of stale) {
      batch.delete(targets[index].ref);
    }
    await batch.commit();
    removed = stale.length;
  }

  return {
    attempted: tokens.length,
    sent: response.successCount,
    failed: response.failureCount,
    removed,
  };
}
