/**
 * Tests for the webhook token → uid resolver.
 *
 * Uses Node's built-in `node:test` runner (no extra dependencies). These cover
 * the pure, Firestore-free paths: token format validation, token generation,
 * and the malformed-token short-circuit in `resolveUserToken` (which returns
 * `null` before issuing any query). Exercising a real lookup belongs in an
 * emulator integration test, not here.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  isValidTokenFormat,
  generateWebhookToken,
  resolveUserToken,
} from "./token";

test("isValidTokenFormat accepts a well-formed url-safe token", () => {
  assert.equal(isValidTokenFormat("abc123_DEF-456ghi"), true);
  assert.equal(isValidTokenFormat(generateWebhookToken()), true);
});

test("isValidTokenFormat rejects non-strings", () => {
  for (const bad of [undefined, null, 42, {}, [], true]) {
    assert.equal(isValidTokenFormat(bad), false);
  }
});

test("isValidTokenFormat rejects too-short and too-long tokens", () => {
  assert.equal(isValidTokenFormat("short"), false); // < 16 chars
  assert.equal(isValidTokenFormat("a".repeat(257)), false); // > 256 chars
  assert.equal(isValidTokenFormat("a".repeat(16)), true);
  assert.equal(isValidTokenFormat("a".repeat(256)), true);
});

test("isValidTokenFormat rejects tokens with disallowed characters", () => {
  for (const bad of [
    "has spaces in it now",
    "has/slash/in/it/now",
    "has.dot.in.it.value",
    "has+plus+in+it+now=",
    "unicodé_token_value_x",
  ]) {
    assert.equal(isValidTokenFormat(bad), false);
  }
});

test("generateWebhookToken produces unique, url-safe 256-bit tokens", () => {
  const a = generateWebhookToken();
  const b = generateWebhookToken();
  assert.notEqual(a, b);
  // 32 bytes base64url (no padding) == 43 chars.
  assert.equal(a.length, 43);
  assert.match(a, /^[A-Za-z0-9_-]+$/);
});

test("resolveUserToken returns null for malformed tokens without querying", async () => {
  // These fail format validation, so they short-circuit before touching
  // Firestore — safe to run with no emulator / credentials.
  for (const bad of [undefined, null, "", "short", "bad/char", 123]) {
    assert.equal(await resolveUserToken(bad), null);
  }
});
