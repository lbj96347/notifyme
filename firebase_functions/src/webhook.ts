/**
 * Webhook receiver — `POST /webhook/{userToken}`.
 *
 * This is the only externally-reachable surface of the stack. The flow:
 *
 *   external system → THIS function → Firestore (notifications) → FCM push
 *
 * The handler:
 *   1. Rejects anything that isn't a POST (405).
 *   2. Extracts `userToken` from the request path and resolves it to a `uid`;
 *      a malformed or unknown token is a 404 (the two are NOT distinguished, so
 *      we never confirm whether a token exists).
 *   3. Validates the JSON body against the shared webhook contract (400).
 *   4. Writes a notification document (201).
 *   5. Pushes the notification to the user's devices via FCM (see `./messaging`).
 *
 * Step 5 is best-effort: the notification is already persisted, so a push
 * failure is logged but never changes the response.
 *
 * Webhook payload contract (kept in sync with the Flutter app and examples/):
 *   { "title": "...", "message": "...", "category": "claude",
 *     "status": "success", "url": "https://..." }
 *
 * Atlassian Statuspage webhooks arrive in a nested, non-flat shape; they are
 * normalized into the flat contract above by `normalizeWebhookBody` (see
 * `./statuspage`) *before* validation, so the rest of the flow is unchanged.
 */
import { onRequest } from "firebase-functions/v2/https";
import type { Request } from "firebase-functions/v2/https";
import type { Response } from "express";
import { resolveUserToken } from "./token";
import { validatePayload } from "./validation";
import { normalizeWebhookBody } from "./statuspage";
import { createNotification } from "./notifications";
import { sendToDevices } from "./messaging";
import type { SendResult } from "./messaging";
import type { ValidatedPayload } from "./validation";

/**
 * The Firestore/FCM-backed collaborators the handler depends on. Bundled behind
 * an interface so tests can inject in-memory fakes and exercise the request flow
 * (token resolution → validation → write → push) without an emulator or
 * credentials. Production uses {@link defaultDeps}.
 */
export interface WebhookDeps {
  resolveUserToken: (token: unknown) => Promise<string | null>;
  createNotification: (uid: string, payload: ValidatedPayload) => Promise<string>;
  sendToDevices: (
    uid: string,
    notificationId: string,
    payload: ValidatedPayload,
  ) => Promise<SendResult>;
}

/** The real, Firebase-backed collaborators used in production. */
export const defaultDeps: WebhookDeps = {
  resolveUserToken,
  createNotification,
  sendToDevices,
};

/**
 * Pull the `userToken` out of a request path.
 *
 * Cloud Functions hands the handler the path *after* the function name, so a
 * call to `/webhook/abc123` arrives here as `/abc123`. We take the last
 * non-empty path segment, which also tolerates a trailing slash and a hosting
 * rewrite that preserves the `/webhook/` prefix. URL-decoded so percent-encoded
 * segments resolve to their literal token (format validation happens downstream
 * in `resolveUserToken`). Returns `undefined` when no segment is present.
 */
export function extractToken(path: string): string | undefined {
  const segments = path.split("/").filter((s) => s.length > 0);
  if (segments.length === 0) {
    return undefined;
  }
  const last = segments[segments.length - 1];
  try {
    return decodeURIComponent(last);
  } catch {
    // Malformed percent-encoding — return as-is and let validation reject it.
    return last;
  }
}

/** Send a JSON response with the given status code. */
function sendJson(res: Response, status: number, body: unknown): void {
  res.status(status).json(body);
}

/**
 * Core handler, separated from the `onRequest` wrapper so it can be exercised
 * directly in tests with stub req/res objects. The Firebase-backed collaborators
 * are injected via `deps` (defaulting to {@link defaultDeps}) so tests can drive
 * the full request flow without an emulator.
 */
export async function handleWebhook(
  req: Request,
  res: Response,
  deps: WebhookDeps = defaultDeps,
): Promise<void> {
  if (req.method !== "POST") {
    res.set("Allow", "POST");
    sendJson(res, 405, { ok: false, error: "method not allowed; use POST" });
    return;
  }

  // Resolve the routing token before doing any work on the body. A malformed
  // or unknown token yields the same 404 — we never reveal which.
  const token = extractToken(req.path);
  const uid = await deps.resolveUserToken(token);
  if (uid === null) {
    sendJson(res, 404, { ok: false, error: "unknown webhook token" });
    return;
  }

  // Statuspage payloads are rewritten into the flat contract here; a native
  // flat (or unrecognized) body passes through untouched.
  const validation = validatePayload(normalizeWebhookBody(req.body));
  if (!validation.ok) {
    sendJson(res, 400, {
      ok: false,
      error: "invalid payload",
      details: validation.errors,
    });
    return;
  }

  let id: string;
  try {
    id = await deps.createNotification(uid, validation.value);
  } catch (err) {
    console.error("failed to write notification", err);
    sendJson(res, 500, { ok: false, error: "internal error" });
    return;
  }

  // Push to the user's devices is best-effort: the notification is already
  // persisted, so a delivery failure must not fail the request. `sendToDevices`
  // also prunes any device whose FCM token is reported as unregistered.
  try {
    const result = await deps.sendToDevices(uid, id, validation.value);
    console.log("pushed notification", { id, ...result });
  } catch (err) {
    console.error("failed to push notification", err);
  }

  sendJson(res, 201, { ok: true, id });
}

/**
 * Exported Cloud Function. `onRequest` parses a JSON body into `req.body`
 * automatically. The token lives in the URL path, not the body.
 */
export const webhook = onRequest(handleWebhook);
