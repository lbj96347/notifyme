/**
 * Webhook payload validation.
 *
 * Validates the shared webhook contract before a notification is written to
 * Firestore and pushed via FCM:
 *
 *   { "title": "...", "message": "...", "category": "claude",
 *     "status": "success", "url": "https://..." }
 *
 * `title` and `message` are required; `category`, `status`, and `url` are
 * optional. This contract is shared across the function, the Flutter app, and
 * the examples/ — keep all three in sync when it changes.
 */

/**
 * Allowed notification statuses. Each maps to a color in the app:
 * `success` = green, `error` = red, `warning` = yellow, `info` = blue.
 * This set is closed — an unknown status is rejected.
 */
export const VALID_STATUSES = ["success", "error", "warning", "info"] as const;

export type Status = (typeof VALID_STATUSES)[number];

/** Default status applied when a payload omits one. */
export const DEFAULT_STATUS: Status = "info";

/**
 * Documented well-known categories, mirroring the `examples/` senders. Unlike
 * statuses, categories are **free-form**: any short label is accepted so a
 * deployer can organize their inbox however they like. This list is a
 * recommendation for documentation and the app's category affordances, not a
 * validation constraint.
 */
export const WELL_KNOWN_CATEGORIES = [
  "claude",
  "codex",
  "ci",
  "github-actions",
  "n8n",
  "bash",
  "general",
] as const;

/**
 * Category applied when a payload omits one. Normalizing here means every
 * notification document carries an explicit category and matches the app's
 * read-time fallback (`defaultNotificationCategory`).
 */
export const DEFAULT_CATEGORY = "general";

/** Reasonable length limits to bound document size and push payloads. */
export const LIMITS = {
  title: 200,
  message: 2000,
  category: 50,
  url: 2048,
} as const;

/** A payload that has passed validation, with defaults applied. */
export interface ValidatedPayload {
  title: string;
  message: string;
  category: string;
  status: Status;
  url?: string;
}

export interface ValidationSuccess {
  ok: true;
  value: ValidatedPayload;
}

export interface ValidationFailure {
  ok: false;
  errors: string[];
}

export type ValidationResult = ValidationSuccess | ValidationFailure;

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Validate and normalize a raw webhook body.
 *
 * Required string fields are trimmed; an empty/whitespace-only required field
 * is rejected. Optional fields are validated only when present. Returns either
 * the normalized payload or the list of human-readable errors.
 */
export function validatePayload(body: unknown): ValidationResult {
  const errors: string[] = [];

  if (!isPlainObject(body)) {
    return { ok: false, errors: ["body must be a JSON object"] };
  }

  const title = validateRequiredString(body.title, "title", LIMITS.title, errors);
  const message = validateRequiredString(body.message, "message", LIMITS.message, errors);
  const category = validateOptionalString(body.category, "category", LIMITS.category, errors);
  const url = validateOptionalString(body.url, "url", LIMITS.url, errors);

  let status: Status = DEFAULT_STATUS;
  if (body.status !== undefined && body.status !== null) {
    if (typeof body.status !== "string") {
      errors.push("status must be a string");
    } else if (!isValidStatus(body.status)) {
      errors.push(`status must be one of: ${VALID_STATUSES.join(", ")}`);
    } else {
      status = body.status;
    }
  }

  if (url !== undefined && !isValidHttpUrl(url)) {
    errors.push("url must be a valid http(s) URL");
  }

  if (errors.length > 0) {
    return { ok: false, errors };
  }

  const value: ValidatedPayload = {
    title: title as string,
    message: message as string,
    category: category ?? DEFAULT_CATEGORY,
    status,
  };
  if (url !== undefined) {
    value.url = url;
  }

  return { ok: true, value };
}

export function isValidStatus(value: string): value is Status {
  return (VALID_STATUSES as readonly string[]).includes(value);
}

function isValidHttpUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
}

function validateRequiredString(
  value: unknown,
  field: string,
  max: number,
  errors: string[],
): string | undefined {
  if (typeof value !== "string") {
    errors.push(`${field} is required and must be a string`);
    return undefined;
  }
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    errors.push(`${field} must not be empty`);
    return undefined;
  }
  if (trimmed.length > max) {
    errors.push(`${field} must be at most ${max} characters`);
    return undefined;
  }
  return trimmed;
}

function validateOptionalString(
  value: unknown,
  field: string,
  max: number,
  errors: string[],
): string | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== "string") {
    errors.push(`${field} must be a string`);
    return undefined;
  }
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  if (trimmed.length > max) {
    errors.push(`${field} must be at most ${max} characters`);
    return undefined;
  }
  return trimmed;
}
