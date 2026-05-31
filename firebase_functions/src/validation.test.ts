/**
 * Tests for the webhook payload validator.
 *
 * Uses Node's built-in test runner (`node:test`) so no extra dev dependency is
 * required. Run against the compiled output: `npm test`.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import {
  DEFAULT_CATEGORY,
  DEFAULT_STATUS,
  LIMITS,
  VALID_STATUSES,
  WELL_KNOWN_CATEGORIES,
  validatePayload,
} from "./validation";

test("accepts a minimal payload with only required fields", () => {
  const result = validatePayload({ title: "Done", message: "Build finished" });
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.value, {
      title: "Done",
      message: "Build finished",
      category: DEFAULT_CATEGORY,
      status: DEFAULT_STATUS,
    });
  }
});

test("accepts a full payload and preserves optional fields", () => {
  const result = validatePayload({
    title: "PR merged",
    message: "feat: webhook validation",
    category: "claude",
    status: "success",
    url: "https://github.com/example/repo/pull/1",
  });
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.value.category, "claude");
    assert.equal(result.value.status, "success");
    assert.equal(result.value.url, "https://github.com/example/repo/pull/1");
  }
});

test("trims required strings", () => {
  const result = validatePayload({ title: "  hi  ", message: "  there  " });
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.value.title, "hi");
    assert.equal(result.value.message, "there");
  }
});

test("rejects a non-object body", () => {
  for (const body of [null, undefined, "string", 42, [], true]) {
    const result = validatePayload(body);
    assert.equal(result.ok, false);
  }
});

test("requires title and message", () => {
  const result = validatePayload({});
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.ok(result.errors.some((e) => e.includes("title")));
    assert.ok(result.errors.some((e) => e.includes("message")));
  }
});

test("rejects empty/whitespace-only required fields", () => {
  const result = validatePayload({ title: "   ", message: "" });
  assert.equal(result.ok, false);
});

test("rejects non-string required fields", () => {
  const result = validatePayload({ title: 1, message: { x: 1 } });
  assert.equal(result.ok, false);
});

test("defaults status to info when omitted", () => {
  const result = validatePayload({ title: "t", message: "m" });
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.value.status, "info");
  }
});

test("accepts every valid status", () => {
  for (const status of VALID_STATUSES) {
    const result = validatePayload({ title: "t", message: "m", status });
    assert.equal(result.ok, true, `status ${status} should be valid`);
    if (result.ok) {
      assert.equal(result.value.status, status);
    }
  }
});

test("rejects an unknown status", () => {
  const result = validatePayload({ title: "t", message: "m", status: "fatal" });
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.ok(result.errors.some((e) => e.includes("status")));
  }
});

test("rejects a non-string status", () => {
  const result = validatePayload({ title: "t", message: "m", status: 1 });
  assert.equal(result.ok, false);
});

test("enforces length limits on title and message", () => {
  const result = validatePayload({
    title: "a".repeat(LIMITS.title + 1),
    message: "b".repeat(LIMITS.message + 1),
  });
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.equal(result.errors.length, 2);
  }
});

test("accepts strings exactly at the limit", () => {
  const result = validatePayload({
    title: "a".repeat(LIMITS.title),
    message: "b".repeat(LIMITS.message),
  });
  assert.equal(result.ok, true);
});

test("defaults category to general when omitted or blank", () => {
  for (const category of [undefined, null, "", "   "]) {
    const result = validatePayload({ title: "t", message: "m", category });
    assert.equal(result.ok, true);
    if (result.ok) {
      assert.equal(result.value.category, DEFAULT_CATEGORY);
    }
  }
});

test("accepts every well-known category and free-form labels", () => {
  for (const category of [...WELL_KNOWN_CATEGORIES, "my-custom-pipeline"]) {
    const result = validatePayload({ title: "t", message: "m", category });
    assert.equal(result.ok, true, `category ${category} should be valid`);
    if (result.ok) {
      assert.equal(result.value.category, category);
    }
  }
});

test("treats an empty optional url as absent", () => {
  const result = validatePayload({ title: "t", message: "m", url: "" });
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.value.url, undefined);
  }
});

test("rejects an invalid url", () => {
  const result = validatePayload({ title: "t", message: "m", url: "not a url" });
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.ok(result.errors.some((e) => e.includes("url")));
  }
});

test("rejects a non-http(s) url scheme", () => {
  const result = validatePayload({
    title: "t",
    message: "m",
    url: "ftp://example.com/file",
  });
  assert.equal(result.ok, false);
});

test("enforces the category length limit", () => {
  const result = validatePayload({
    title: "t",
    message: "m",
    category: "c".repeat(LIMITS.category + 1),
  });
  assert.equal(result.ok, false);
});
