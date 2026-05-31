/// Category values carried by the webhook payload's `category` field. Categories
/// organize the inbox (and back the `uid + category + createdAt` Firestore
/// index) — they are **free-form by design**: a deployer can send any short
/// label that suits their tooling.
///
/// The list below is the documented set of *well-known* categories that the
/// `examples/` ship with and the UI is expected to handle gracefully. It is a
/// recommendation, not a constraint — unknown categories are accepted and
/// rendered as-is. This contract is shared across the Cloud Function, this app,
/// and the `examples/` — keep them in sync.
library;

/// The category applied when a webhook payload omits one. The Cloud Function
/// normalizes a missing/empty `category` to this value before writing, so every
/// notification document carries an explicit category; this fallback also guards
/// older documents written before that normalization.
const String defaultNotificationCategory = 'general';

/// Documented well-known categories, mirroring the `examples/` subdirectories
/// and the driving use cases in the PRD. Free-form labels outside this set are
/// still valid — this list exists for documentation and (future) UI affordances
/// such as category icons or quick filters.
const List<String> wellKnownNotificationCategories = <String>[
  'claude', // Claude Code jobs
  'codex', // Codex CLI runs
  'ci', // generic CI / build pipelines
  'github-actions', // GitHub Actions workflows
  'n8n', // n8n workflows
  'bash', // plain shell / curl senders
  defaultNotificationCategory, // uncategorized / catch-all
];
