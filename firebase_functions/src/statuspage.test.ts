/**
 * Tests for Atlassian Statuspage payload normalization.
 *
 * Uses Node's built-in test runner (`node:test`). These verify two things:
 *   1. Statuspage incident and component payloads are rewritten into the flat
 *      NotifyMe contract, and the result survives `validatePayload`.
 *   2. Native flat payloads (and unrecognized bodies) pass through untouched, so
 *      the existing contract is never broken.
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import {
  STATUSPAGE_CATEGORY,
  isStatuspagePayload,
  normalizeWebhookBody,
} from "./statuspage";
import { validatePayload } from "./validation";

// A representative Statuspage incident webhook (trimmed to the fields we read).
const INCIDENT_PAYLOAD = {
  meta: { unsubscribe: "...", documentation: "..." },
  page: { id: "pg1", status_indicator: "major", status_description: "Partial Outage" },
  incident: {
    name: "API latency elevated",
    status: "investigating",
    impact: "major",
    shortlink: "http://stspg.io/abc123",
    incident_updates: [
      { body: "We are investigating elevated API latency.", status: "investigating" },
      { body: "Older update that should be ignored.", status: "investigating" },
    ],
  },
};

// A representative Statuspage component-update webhook.
const COMPONENT_PAYLOAD = {
  meta: { unsubscribe: "..." },
  page: { id: "pg1", status_indicator: "none", status_description: "All Systems Operational" },
  component_update: {
    new_status: "operational",
    old_status: "major_outage",
    component_id: "c1",
  },
  component: { id: "c1", name: "Web API", status: "operational" },
};

test("detects incident and component payloads", () => {
  assert.equal(isStatuspagePayload(INCIDENT_PAYLOAD), true);
  assert.equal(isStatuspagePayload(COMPONENT_PAYLOAD), true);
  // Component-only shape (no component_update wrapper) is still detected.
  assert.equal(isStatuspagePayload({ component: { name: "X", status: "operational" } }), true);
});

test("does not treat native flat payloads as Statuspage", () => {
  assert.equal(isStatuspagePayload({ title: "t", message: "m" }), false);
  // A flat payload that happens to omit one field is still left alone.
  assert.equal(isStatuspagePayload({ title: "t" }), false);
  assert.equal(isStatuspagePayload({ message: "m" }), false);
});

test("does not treat unrelated/non-object bodies as Statuspage", () => {
  for (const body of [null, undefined, "string", 42, [], { foo: "bar" }]) {
    assert.equal(isStatuspagePayload(body), false);
  }
});

test("normalizes an incident into the flat contract", () => {
  const flat = normalizeWebhookBody(INCIDENT_PAYLOAD) as Record<string, unknown>;
  assert.equal(flat.title, "API latency elevated — investigating");
  assert.equal(flat.message, "We are investigating elevated API latency.");
  assert.equal(flat.category, STATUSPAGE_CATEGORY);
  assert.equal(flat.status, "error"); // active + major impact
  assert.equal(flat.url, "http://stspg.io/abc123");

  // And it survives the existing validation flow unchanged.
  const result = validatePayload(flat);
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.value.status, "error");
    assert.equal(result.value.category, STATUSPAGE_CATEGORY);
    assert.equal(result.value.url, "http://stspg.io/abc123");
  }
});

test("maps incident lifecycle/impact to status colors", () => {
  const color = (status: string, impact: string) => {
    const flat = normalizeWebhookBody({
      incident: { name: "n", status, impact, incident_updates: [] },
    }) as Record<string, unknown>;
    return flat.status;
  };
  assert.equal(color("resolved", "critical"), "success"); // resolved wins over impact
  assert.equal(color("postmortem", "major"), "info");
  assert.equal(color("monitoring", "major"), "warning");
  assert.equal(color("identified", "critical"), "error");
  assert.equal(color("investigating", "minor"), "warning");
  assert.equal(color("investigating", "none"), "info");
  assert.equal(color("investigating", "weird"), "warning"); // active default
});

test("incident with no usable update falls back to an impact/status summary", () => {
  const flat = normalizeWebhookBody({
    incident: { name: "DB down", status: "identified", impact: "critical", incident_updates: [] },
  }) as Record<string, unknown>;
  assert.equal(flat.title, "DB down — identified");
  assert.equal(flat.message, "Impact: critical, status: identified");
  assert.equal(flat.status, "error");
  // No shortlink → no url field at all (not an empty string).
  assert.equal("url" in flat, false);
});

test("normalizes a component update into the flat contract", () => {
  const flat = normalizeWebhookBody(COMPONENT_PAYLOAD) as Record<string, unknown>;
  assert.equal(flat.title, "Web API is operational");
  assert.equal(flat.message, "Web API changed from major outage to operational.");
  assert.equal(flat.category, STATUSPAGE_CATEGORY);
  assert.equal(flat.status, "success");

  const result = validatePayload(flat);
  assert.equal(result.ok, true);
});

test("maps component status to status colors", () => {
  const color = (newStatus: string) => {
    const flat = normalizeWebhookBody({
      component: { name: "c", status: newStatus },
    }) as Record<string, unknown>;
    return flat.status;
  };
  assert.equal(color("operational"), "success");
  assert.equal(color("degraded_performance"), "warning");
  assert.equal(color("partial_outage"), "warning");
  assert.equal(color("major_outage"), "error");
  assert.equal(color("under_maintenance"), "info");
  assert.equal(color("unknown_value"), "info");
});

test("component-only payload (no update wrapper) uses the component status", () => {
  const flat = normalizeWebhookBody({
    component: { name: "Web API", status: "major_outage" },
  }) as Record<string, unknown>;
  assert.equal(flat.title, "Web API is major outage");
  assert.equal(flat.message, "Web API is now major outage.");
  assert.equal(flat.status, "error");
});

test("leaves native flat payloads untouched", () => {
  const native = {
    title: "Build passed",
    message: "main is green",
    category: "ci",
    status: "success",
  };
  // Same reference back — no rewrite.
  assert.equal(normalizeWebhookBody(native), native);
});

test("leaves unrecognized bodies untouched for the validator to reject", () => {
  const junk = { foo: "bar" };
  assert.equal(normalizeWebhookBody(junk), junk);
  assert.equal(normalizeWebhookBody(null), null);
  assert.equal(normalizeWebhookBody("nope"), "nope");
});
