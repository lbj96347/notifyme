/**
 * Atlassian Statuspage webhook normalization.
 *
 * Statuspage (https://www.atlassian.com/software/statuspage) posts webhooks in
 * its own nested shape rather than the flat NotifyMe contract. This module
 * detects those payloads and rewrites them into the flat
 * `{ title, message, category, status, url }` shape so the *existing*
 * `validatePayload` flow can validate and normalize them like any other body.
 *
 * Two Statuspage payload kinds are supported:
 *
 *   - **Incident** — carries a top-level `incident` object. The notification
 *     title is the incident name + lifecycle status; the message is the latest
 *     incident-update body; the status color is derived from the incident's
 *     lifecycle status and impact; the url is the incident shortlink.
 *
 *   - **Component update** — carries a top-level `component_update` (and usually
 *     `component`) object. The notification describes the component's status
 *     transition; the status color is derived from the new component status.
 *
 * Detection is conservative: a body that already speaks the NotifyMe contract
 * (a top-level `title` or `message`) is returned untouched, so native flat
 * payloads are never reinterpreted. A body that looks like neither is returned
 * untouched too, leaving `validatePayload` to reject it as before.
 *
 * The normalized output is a *raw* body (status strings, no trimming): it is
 * fed straight into `validatePayload`, which owns trimming, length limits, and
 * the closed status set. The status colors produced here are always members of
 * that closed set.
 */

/** Category stamped on every normalized Statuspage notification. */
export const STATUSPAGE_CATEGORY = "statuspage";

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

/** Turn a Statuspage enum token (`major_outage`) into prose (`major outage`). */
function humanize(value: string): string {
  return value.replace(/_/g, " ").trim();
}

/**
 * Map an incident's lifecycle status + impact to a NotifyMe status color.
 *
 * Lifecycle wins where it's unambiguous: a `resolved` incident is a success
 * regardless of how bad it was, and `postmortem` is informational. An active
 * incident (`investigating` / `identified`, or an unrecognized status) takes its
 * color from impact — `critical`/`major` is an error, `minor` a warning,
 * `none`/`maintenance` info — defaulting to `warning` so an active incident is
 * never silently downgraded to `info`.
 */
function incidentStatusColor(status: string, impact: string): string {
  switch (status) {
    case "resolved":
      return "success";
    case "postmortem":
      return "info";
    case "monitoring":
      return "warning";
    default:
      break;
  }
  switch (impact) {
    case "critical":
    case "major":
      return "error";
    case "minor":
      return "warning";
    case "none":
    case "maintenance":
      return "info";
    default:
      return "warning";
  }
}

/** Map a component status to a NotifyMe status color. */
function componentStatusColor(status: string): string {
  switch (status) {
    case "operational":
      return "success";
    case "degraded_performance":
    case "partial_outage":
      return "warning";
    case "major_outage":
      return "error";
    case "under_maintenance":
      return "info";
    default:
      return "info";
  }
}

/** Build the flat body for a Statuspage incident payload. */
function normalizeIncident(incident: Record<string, unknown>): Record<string, unknown> {
  const name = asString(incident.name) || "Incident update";
  const status = asString(incident.status);
  const impact = asString(incident.impact);

  // `incident_updates` is ordered most-recent-first; take the latest entry that
  // actually carries a body for the notification message.
  const updates = Array.isArray(incident.incident_updates) ? incident.incident_updates : [];
  const latest = updates.find(
    (u): u is Record<string, unknown> => isPlainObject(u) && asString(u.body).trim().length > 0,
  );
  const updateBody = latest ? asString(latest.body) : "";

  const title = status ? `${name} — ${humanize(status)}` : name;
  const message =
    updateBody ||
    `Impact: ${humanize(impact) || "unknown"}, status: ${humanize(status) || "unknown"}`;

  const body: Record<string, unknown> = {
    title,
    message,
    category: STATUSPAGE_CATEGORY,
    status: incidentStatusColor(status, impact),
  };

  const shortlink = asString(incident.shortlink);
  if (shortlink) {
    body.url = shortlink;
  }
  return body;
}

/** Build the flat body for a Statuspage component-update payload. */
function normalizeComponent(payload: Record<string, unknown>): Record<string, unknown> {
  const component = isPlainObject(payload.component) ? payload.component : {};
  const update = isPlainObject(payload.component_update) ? payload.component_update : {};

  const name = asString(component.name) || "Component";
  // The update record carries the transition; fall back to the component's own
  // status when only the component object is present.
  const newStatus = asString(update.new_status) || asString(component.status);
  const oldStatus = asString(update.old_status);

  const title = `${name} is ${humanize(newStatus) || "updated"}`;
  const message =
    oldStatus && newStatus
      ? `${name} changed from ${humanize(oldStatus)} to ${humanize(newStatus)}.`
      : `${name} is now ${humanize(newStatus) || "updated"}.`;

  return {
    title,
    message,
    category: STATUSPAGE_CATEGORY,
    status: componentStatusColor(newStatus),
  };
}

/**
 * True if `body` looks like a Statuspage webhook (and not a native flat
 * payload). Used by {@link normalizeWebhookBody}; exported for testing.
 */
export function isStatuspagePayload(body: unknown): boolean {
  if (!isPlainObject(body)) {
    return false;
  }
  // Never reinterpret a payload that already speaks the NotifyMe contract.
  if ("title" in body || "message" in body) {
    return false;
  }
  return (
    isPlainObject(body.incident) ||
    isPlainObject(body.component_update) ||
    isPlainObject(body.component)
  );
}

/**
 * Normalize a raw webhook body before validation.
 *
 * Returns the flat NotifyMe shape when `body` is a recognized Statuspage
 * payload, otherwise returns `body` unchanged so existing flat payloads (and
 * anything unrecognized) flow through to `validatePayload` exactly as before.
 */
export function normalizeWebhookBody(body: unknown): unknown {
  if (!isStatuspagePayload(body) || !isPlainObject(body)) {
    return body;
  }
  if (isPlainObject(body.incident)) {
    return normalizeIncident(body.incident);
  }
  return normalizeComponent(body);
}
