/**
 * End-to-end tests for the webhook normalization → validation path.
 *
 * The receiver runs `validatePayload(normalizeWebhookBody(body))` before
 * persisting anything (see `webhook.ts`). The `statuspage.test.ts` suite covers
 * normalization in isolation and `webhook.test.ts` covers the request flow; this
 * suite pins the *composition* — every supported body shape, fed through both
 * steps in order, ending in either a fully-normalized `ValidatedPayload` or a
 * rejection. One scenario per case the contract promises to handle:
 *
 *   - native flat NotifyMe payloads (the additive baseline)
 *   - Statuspage incidents (active, resolved)
 *   - incident impact → status-color mapping (critical / major)
 *   - Statuspage component updates (operational recovery, major outage)
 *   - unknown / invalid bodies the validator must reject
 */
import { strict as assert } from "node:assert";
import { test } from "node:test";

import { normalizeWebhookBody } from "./statuspage";
import { validatePayload } from "./validation";
import type { ValidatedPayload } from "./validation";

/**
 * Run a raw webhook body through the exact pipeline the handler uses and assert
 * it validates, returning the normalized payload for further assertions.
 */
function accept(body: unknown): ValidatedPayload {
  const result = validatePayload(normalizeWebhookBody(body));
  assert.equal(result.ok, true, `expected body to validate: ${JSON.stringify(result)}`);
  if (!result.ok) {
    throw new Error("unreachable"); // narrow the type for callers
  }
  return result.value;
}

/** Run a body through the pipeline and assert the validator rejects it. */
function reject(body: unknown): string[] {
  const result = validatePayload(normalizeWebhookBody(body));
  assert.equal(result.ok, false, `expected body to be rejected: ${JSON.stringify(result)}`);
  if (result.ok) {
    throw new Error("unreachable");
  }
  return result.errors;
}

test("flat NotifyMe payload passes through and gets defaults applied", () => {
  const value = accept({ title: "Build passed", message: "main is green" });
  assert.equal(value.title, "Build passed");
  assert.equal(value.message, "main is green");
  // No category/status in the body → contract defaults, not Statuspage values.
  assert.equal(value.category, "general");
  assert.equal(value.status, "info");
  assert.equal("url" in value, false);
});

test("flat NotifyMe payload preserves an explicit category/status/url", () => {
  const value = accept({
    title: "PR merged",
    message: "feat: webhook handler",
    category: "claude",
    status: "success",
    url: "https://github.com/acme/app/pull/1",
  });
  assert.equal(value.category, "claude");
  assert.equal(value.status, "success");
  assert.equal(value.url, "https://github.com/acme/app/pull/1");
});

test("Statuspage incident (active) normalizes and validates", () => {
  const value = accept({
    page: { id: "pg1" },
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
  });
  assert.equal(value.title, "API latency elevated — investigating");
  // Latest (first) update body wins for the message.
  assert.equal(value.message, "We are investigating elevated API latency.");
  assert.equal(value.category, "statuspage");
  assert.equal(value.status, "error"); // active + major impact
  assert.equal(value.url, "http://stspg.io/abc123");
});

test("Statuspage resolved incident maps to success regardless of impact", () => {
  const value = accept({
    incident: {
      name: "API latency elevated",
      status: "resolved",
      impact: "critical",
      shortlink: "http://stspg.io/abc123",
      incident_updates: [{ body: "This incident has been resolved.", status: "resolved" }],
    },
  });
  assert.equal(value.title, "API latency elevated — resolved");
  assert.equal(value.message, "This incident has been resolved.");
  assert.equal(value.status, "success"); // lifecycle wins over critical impact
  assert.equal(value.category, "statuspage");
});

test("Statuspage active incident impact critical and major both map to error", () => {
  for (const impact of ["critical", "major"]) {
    const value = accept({
      incident: { name: "Outage", status: "identified", impact, incident_updates: [] },
    });
    assert.equal(value.status, "error", `impact ${impact} should be error`);
    // No usable update → impact/status summary message, no url field.
    assert.equal(value.message, `Impact: ${impact}, status: identified`);
    assert.equal("url" in value, false);
  }
});

test("Statuspage component update — operational recovery maps to success", () => {
  const value = accept({
    page: { id: "pg1" },
    component_update: { new_status: "operational", old_status: "major_outage", component_id: "c1" },
    component: { id: "c1", name: "Web API", status: "operational" },
  });
  assert.equal(value.title, "Web API is operational");
  assert.equal(value.message, "Web API changed from major outage to operational.");
  assert.equal(value.category, "statuspage");
  assert.equal(value.status, "success");
});

test("Statuspage component update — major outage maps to error", () => {
  const value = accept({
    component_update: { new_status: "major_outage", old_status: "operational", component_id: "c1" },
    component: { id: "c1", name: "Web API", status: "major_outage" },
  });
  assert.equal(value.title, "Web API is major outage");
  assert.equal(value.message, "Web API changed from operational to major outage.");
  assert.equal(value.status, "error");
  assert.equal(value.category, "statuspage");
});

test("unknown/invalid bodies are rejected by the validator", () => {
  // Unrecognized object: not Statuspage, missing required fields.
  assert.ok(reject({ foo: "bar" }).length > 0);
  // Non-object bodies.
  for (const body of [null, undefined, "nope", 42, []]) {
    assert.ok(reject(body).length > 0, `expected ${JSON.stringify(body)} to be rejected`);
  }
  // A flat-looking body with an out-of-set status is normalized as-is, then
  // rejected by the closed status check — surfacing a status-specific error.
  const errors = reject({ title: "t", message: "m", status: "fatal" });
  assert.ok(errors.some((e) => e.includes("status")));
});
