/**
 * Tests for the webhook receiver.
 *
 * Uses Node's built-in `node:test` runner (no extra dependencies). These cover
 * the Firestore-free paths: token extraction from the path, the non-POST
 * rejection, and the malformed-token 404 (which short-circuits in
 * `resolveUserToken` before any query).
 *
 * The validation, unknown-token, and valid-payload paths normally touch
 * Firestore/FCM. Rather than stand up an emulator, we inject in-memory fakes via
 * the handler's `deps` parameter so the full request flow can be exercised with
 * no credentials. End-to-end behavior against real Firestore still belongs in a
 * separate emulator integration test.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import type { Request } from "firebase-functions/v2/https";
import type { Response } from "express";
import { extractToken, handleWebhook } from "./webhook";
import type { WebhookDeps } from "./webhook";
import type { ValidatedPayload } from "./validation";
import type { SendResult } from "./messaging";

/** Minimal Response stub that records what the handler sent. */
function stubResponse(): Response & {
  statusCode: number;
  body: unknown;
  headers: Record<string, string>;
} {
  const res = {
    statusCode: 0,
    body: undefined as unknown,
    headers: {} as Record<string, string>,
    status(code: number) {
      this.statusCode = code;
      return this;
    },
    json(payload: unknown) {
      this.body = payload;
      return this;
    },
    set(key: string, value: string) {
      this.headers[key] = value;
      return this;
    },
  };
  return res as unknown as Response & {
    statusCode: number;
    body: unknown;
    headers: Record<string, string>;
  };
}

function stubRequest(method: string, path: string, body?: unknown): Request {
  return { method, path, body } as unknown as Request;
}

const NO_DEVICES: SendResult = { attempted: 0, sent: 0, failed: 0, removed: 0 };

/**
 * In-memory `WebhookDeps` that records what the handler did. By default the
 * token resolves to a uid, the write succeeds, and the push no-ops — i.e. the
 * happy path. Override individual members to exercise other branches.
 */
function fakeDeps(overrides: Partial<WebhookDeps> = {}): WebhookDeps & {
  created: { uid: string; payload: ValidatedPayload }[];
  pushed: { uid: string; id: string }[];
} {
  const created: { uid: string; payload: ValidatedPayload }[] = [];
  const pushed: { uid: string; id: string }[] = [];
  return {
    created,
    pushed,
    resolveUserToken: async () => "user-1",
    createNotification: async (uid, payload) => {
      created.push({ uid, payload });
      return "note-123";
    },
    sendToDevices: async (uid, id) => {
      pushed.push({ uid, id });
      return NO_DEVICES;
    },
    ...overrides,
  };
}

/** A valid body so non-validation tests reach the path under test. */
const VALID_BODY = { title: "Build passed", message: "main is green" };

test("extractToken returns the last non-empty path segment", () => {
  assert.equal(extractToken("/abc123"), "abc123");
  assert.equal(extractToken("/webhook/abc123"), "abc123");
  assert.equal(extractToken("/abc123/"), "abc123");
  assert.equal(extractToken("abc123"), "abc123");
});

test("extractToken url-decodes the segment", () => {
  assert.equal(extractToken("/tok%2Den"), "tok-en");
});

test("extractToken returns undefined for an empty path", () => {
  assert.equal(extractToken("/"), undefined);
  assert.equal(extractToken(""), undefined);
});

test("handleWebhook rejects non-POST methods with 405 and Allow header", async () => {
  for (const method of ["GET", "PUT", "DELETE", "PATCH"]) {
    const res = stubResponse();
    await handleWebhook(stubRequest(method, "/anytoken"), res);
    assert.equal(res.statusCode, 405);
    assert.equal(res.headers["Allow"], "POST");
    assert.deepEqual(res.body, {
      ok: false,
      error: "method not allowed; use POST",
    });
  }
});

test("handleWebhook returns 404 for a malformed token without querying", async () => {
  // A malformed token short-circuits in resolveUserToken (no Firestore call),
  // so this is safe to run with no emulator / credentials.
  const res = stubResponse();
  await handleWebhook(stubRequest("POST", "/bad token", { title: "t" }), res);
  assert.equal(res.statusCode, 404);
  assert.deepEqual(res.body, { ok: false, error: "unknown webhook token" });
});

test("handleWebhook returns 404 for an unknown token and does no work", async () => {
  // Token is well-formed but owned by nobody: resolveUserToken returns null.
  const deps = fakeDeps({ resolveUserToken: async () => null });
  const res = stubResponse();
  await handleWebhook(stubRequest("POST", "/unknown_token_123456", VALID_BODY), res, deps);
  assert.equal(res.statusCode, 404);
  assert.deepEqual(res.body, { ok: false, error: "unknown webhook token" });
  // No notification written and no push attempted for an unresolved token.
  assert.equal(deps.created.length, 0);
  assert.equal(deps.pushed.length, 0);
});

test("handleWebhook returns 400 when title or message is missing", async () => {
  // Token resolves fine; the body is what's rejected. No write/push should run.
  for (const body of [
    { message: "no title here" }, // missing title
    { title: "no message here" }, // missing message
    {}, // both missing
  ]) {
    const deps = fakeDeps();
    const res = stubResponse();
    await handleWebhook(stubRequest("POST", "/valid_token_123456", body), res, deps);
    assert.equal(res.statusCode, 400);
    const failure = res.body as { ok: boolean; error: string; details: string[] };
    assert.equal(failure.ok, false);
    assert.equal(failure.error, "invalid payload");
    assert.ok(Array.isArray(failure.details) && failure.details.length > 0);
    assert.equal(deps.created.length, 0);
    assert.equal(deps.pushed.length, 0);
  }
});

test("handleWebhook returns 400 for an invalid status", async () => {
  const deps = fakeDeps();
  const res = stubResponse();
  await handleWebhook(
    stubRequest("POST", "/valid_token_123456", {
      ...VALID_BODY,
      status: "fatal",
    }),
    res,
    deps,
  );
  assert.equal(res.statusCode, 400);
  const failure = res.body as { ok: boolean; error: string; details: string[] };
  assert.equal(failure.error, "invalid payload");
  assert.ok(failure.details.some((d) => d.includes("status")));
  assert.equal(deps.created.length, 0);
});

test("handleWebhook writes, pushes, and returns 201 for a valid payload", async () => {
  const deps = fakeDeps();
  const res = stubResponse();
  await handleWebhook(
    stubRequest("POST", "/valid_token_123456", {
      title: "PR merged",
      message: "feat: webhook handler",
      category: "claude",
      status: "success",
      url: "https://github.com/acme/app/pull/1",
    }),
    res,
    deps,
  );

  assert.equal(res.statusCode, 201);
  assert.deepEqual(res.body, { ok: true, id: "note-123" });

  // The validated, normalized payload reached the writer under the resolved uid.
  assert.equal(deps.created.length, 1);
  assert.equal(deps.created[0].uid, "user-1");
  assert.equal(deps.created[0].payload.title, "PR merged");
  assert.equal(deps.created[0].payload.status, "success");
  assert.equal(deps.created[0].payload.category, "claude");

  // The new notification id was pushed to that user's devices.
  assert.deepEqual(deps.pushed, [{ uid: "user-1", id: "note-123" }]);
});

test("handleWebhook still returns 201 when the push fails (best-effort)", async () => {
  // A delivery failure must not fail the request: the notification is persisted.
  const deps = fakeDeps({
    sendToDevices: async () => {
      throw new Error("FCM unavailable");
    },
  });
  const res = stubResponse();
  await handleWebhook(stubRequest("POST", "/valid_token_123456", VALID_BODY), res, deps);
  assert.equal(res.statusCode, 201);
  assert.deepEqual(res.body, { ok: true, id: "note-123" });
  assert.equal(deps.created.length, 1);
});

test("handleWebhook returns 500 when the notification write fails", async () => {
  const deps = fakeDeps({
    createNotification: async () => {
      throw new Error("Firestore unavailable");
    },
  });
  const res = stubResponse();
  await handleWebhook(stubRequest("POST", "/valid_token_123456", VALID_BODY), res, deps);
  assert.equal(res.statusCode, 500);
  assert.deepEqual(res.body, { ok: false, error: "internal error" });
  assert.equal(deps.pushed.length, 0);
});
