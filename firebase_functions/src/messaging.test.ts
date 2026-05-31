/**
 * Tests for the FCM push sender.
 *
 * Uses Node's built-in `node:test` runner (no extra dependencies). These cover
 * the pure, Firestore/FCM-free paths: building the data payload, assembling the
 * multicast message, and identifying unregistered tokens from send responses.
 * Exercising `sendToDevices` end-to-end (which queries Firestore and calls FCM)
 * belongs in an emulator integration test, not here.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import type { SendResponse } from "firebase-admin/messaging";
import {
  buildDataPayload,
  buildMulticastMessage,
  unregisteredTokenIndexes,
} from "./messaging";
import type { ValidatedPayload } from "./validation";

const MINIMAL: ValidatedPayload = {
  title: "Build passed",
  message: "main is green",
  status: "success",
  category: "general",
};

const FULL: ValidatedPayload = {
  title: "PR merged",
  message: "feat: fcm sender",
  status: "info",
  category: "claude",
  url: "https://github.com/acme/app/pull/1",
};

test("buildDataPayload includes the required string fields", () => {
  const data = buildDataPayload("note-1", MINIMAL);
  assert.deepEqual(data, {
    notificationId: "note-1",
    title: "Build passed",
    body: "main is green",
    status: "success",
    category: "general",
  });
});

test("buildDataPayload carries category and url when present", () => {
  const data = buildDataPayload("note-2", FULL);
  assert.equal(data.category, "claude");
  assert.equal(data.url, "https://github.com/acme/app/pull/1");
});

test("buildDataPayload always carries category and omits an absent url", () => {
  const data = buildDataPayload("note-3", MINIMAL);
  assert.equal(data.category, "general");
  assert.equal("url" in data, false);
});

test("buildDataPayload emits only string values (FCM requirement)", () => {
  const data = buildDataPayload("note-4", FULL);
  for (const value of Object.values(data)) {
    assert.equal(typeof value, "string");
  }
});

test("buildMulticastMessage sets notification title/body and data payload", () => {
  const message = buildMulticastMessage(["tokA", "tokB"], "note-5", FULL);
  assert.deepEqual(message.tokens, ["tokA", "tokB"]);
  assert.deepEqual(message.notification, {
    title: "PR merged",
    body: "feat: fcm sender",
  });
  assert.equal(message.data?.notificationId, "note-5");
  assert.equal(message.data?.url, "https://github.com/acme/app/pull/1");
});

test("unregisteredTokenIndexes flags unregistered and invalid tokens", () => {
  const responses: SendResponse[] = [
    { success: true, messageId: "m0" },
    {
      success: false,
      error: makeError("messaging/registration-token-not-registered"),
    },
    {
      success: false,
      error: makeError("messaging/invalid-registration-token"),
    },
    { success: false, error: makeError("messaging/invalid-argument") },
  ];
  assert.deepEqual(unregisteredTokenIndexes(responses), [1, 2, 3]);
});

test("unregisteredTokenIndexes ignores transient failures and successes", () => {
  const responses: SendResponse[] = [
    { success: true, messageId: "m0" },
    { success: false, error: makeError("messaging/internal-error") },
    { success: false, error: makeError("messaging/server-unavailable") },
  ];
  assert.deepEqual(unregisteredTokenIndexes(responses), []);
});

test("unregisteredTokenIndexes returns empty for an all-success batch", () => {
  const responses: SendResponse[] = [
    { success: true, messageId: "m0" },
    { success: true, messageId: "m1" },
  ];
  assert.deepEqual(unregisteredTokenIndexes(responses), []);
});

/** Build a minimal FirebaseError-shaped object with the given code. */
function makeError(code: string): SendResponse["error"] {
  return {
    code,
    message: code,
    name: "FirebaseError",
  } as unknown as SendResponse["error"];
}
