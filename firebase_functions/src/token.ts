/**
 * Webhook token → uid resolution.
 *
 * The webhook URL is `POST /webhook/{userToken}`. `userToken` is the routing
 * key: it identifies *which* user a notification belongs to. This module turns
 * that opaque token into the owning `uid` so the handler can write the
 * notification and look up the user's device FCM tokens.
 *
 * MVP storage model
 * -----------------
 * Each user document carries a `webhookToken` field:
 *
 *   users/{uid} = { uid, email, createdAt, webhookToken }
 *
 * Resolution is a single-field equality query — `where("webhookToken", "==", t)`
 * — which Firestore serves from its *automatic* single-field index. No
 * composite index and therefore no `firestore.indexes.json` to deploy, which
 * keeps the stack self-host-friendly (a fresh Firebase project works as-is).
 *
 * The token is a routing key, not a password. The MVP relies on it being an
 * unguessable random string (high entropy; see `generateWebhookToken`) rather
 * than on a verified secret. v2 layers an `Authorization: Bearer` secret on top
 * of this lookup — that auth check is intentionally NOT implemented here.
 */
import { randomBytes } from "crypto";
import { db } from "./admin";

/** Firestore collection holding one document per user, keyed by `uid`. */
export const USERS_COLLECTION = "users";

/** Field on the user document that stores the webhook routing token. */
export const WEBHOOK_TOKEN_FIELD = "webhookToken";

/**
 * Number of random bytes behind a generated token. 32 bytes = 256 bits of
 * entropy, rendered as 43 url-safe base64 characters — infeasible to guess.
 */
const TOKEN_BYTES = 32;

/**
 * Bounds on an acceptable token string. We reject anything outside this range
 * before touching Firestore so malformed path segments can't trigger a query.
 * The lower bound rejects trivially weak tokens; the upper bound caps work.
 */
const MIN_TOKEN_LENGTH = 16;
const MAX_TOKEN_LENGTH = 256;

/**
 * A token is a url-safe string: unreserved URL characters only. This lets it
 * sit in a path segment without encoding and matches `generateWebhookToken`
 * output. Validation is purely structural — it does not prove the token exists.
 */
const TOKEN_PATTERN = /^[A-Za-z0-9_-]+$/;

/**
 * Structurally validate a raw token taken from the request path.
 *
 * Returns `true` only for non-empty, correctly-shaped tokens of a sane length.
 * Callers should use this to reject obvious garbage (and yield a `404`) before
 * issuing a Firestore query.
 */
export function isValidTokenFormat(token: unknown): token is string {
  return (
    typeof token === "string" &&
    token.length >= MIN_TOKEN_LENGTH &&
    token.length <= MAX_TOKEN_LENGTH &&
    TOKEN_PATTERN.test(token)
  );
}

/**
 * Resolve a webhook `userToken` to the owning user's `uid`.
 *
 * Returns the `uid` on success, or `null` when the token is malformed or no
 * user owns it. The handler should treat `null` as a `404` and MUST NOT leak
 * whether the token was unknown vs. malformed.
 *
 * Runs with Admin privileges (see `./admin`), so it bypasses Firestore security
 * rules — that is what lets an *unauthenticated* webhook caller be mapped to a
 * user. The query is capped at one result; tokens are expected to be unique.
 */
export async function resolveUserToken(token: unknown): Promise<string | null> {
  if (!isValidTokenFormat(token)) {
    return null;
  }

  const snapshot = await db
    .collection(USERS_COLLECTION)
    .where(WEBHOOK_TOKEN_FIELD, "==", token)
    .limit(1)
    .get();

  if (snapshot.empty) {
    return null;
  }

  // Document id is the uid (the `users` collection is keyed by uid).
  return snapshot.docs[0].id;
}

/**
 * Generate a fresh, unguessable webhook token.
 *
 * Provided for whoever provisions users (the app's sign-up flow, or a setup
 * script). Produces a 256-bit url-safe base64 string with no padding, so it is
 * safe to drop straight into the webhook URL path. Uses Node's crypto, which is
 * available in the Cloud Functions runtime.
 */
export function generateWebhookToken(): string {
  return randomBytes(TOKEN_BYTES).toString("base64url");
}
