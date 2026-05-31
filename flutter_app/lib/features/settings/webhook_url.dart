// Webhook URL construction (client side).
//
// Turns a user's `webhookToken` into the full URL they paste into integrations:
//
//   POST https://<region>-<projectId>.cloudfunctions.net/webhook/<token>
//
// The base must be *configurable per deployment* — NotifyMe is self-hosted, so
// every developer points the app at their own Firebase project (different
// projectId, possibly a different functions region, or a custom-domain hosting
// rewrite in front of the function). We never hardcode a project ID (see
// CLAUDE.md), so the default base is derived at runtime from the project ID
// baked into `firebase_options.dart`, and can be overridden wholesale.
//
// Configuration, highest precedence first:
//   1. `--dart-define=NOTIFYME_WEBHOOK_BASE_URL=https://hooks.example.com/webhook`
//      A full base URL (everything up to but not including `/<token>`). Use this
//      for a Firebase Hosting rewrite or custom domain in front of the function.
//   2. `--dart-define=NOTIFYME_FUNCTIONS_REGION=europe-west1`
//      Just the Cloud Functions region; the rest of the default URL is derived
//      from the project ID. Defaults to `us-central1` (the region the function
//      deploys to when none is set — see firebase_functions/src/webhook.ts).
//
// The `_FUNCTIONS_REGION` override is ignored when a full `_BASE_URL` is given.

/// Default Cloud Functions region. Matches the region a v2 `onRequest` function
/// deploys to when it sets none, which is the case for `webhook` today.
const String _defaultRegion = 'us-central1';

/// Name of the deployed function, the path prefix the webhook is served under.
const String _functionName = 'webhook';

/// Resolves a user's webhook token into the URL they paste into integrations.
///
/// Construct once (typically [WebhookUrlBuilder.fromEnvironment]) and reuse.
/// Pure and Firebase-free so it can be unit-tested without a live app; callers
/// pass in the `projectId` (read from `Firebase.app().options.projectId`).
class WebhookUrlBuilder {
  /// A full base URL (no trailing `/<token>`), e.g. a hosting rewrite or custom
  /// domain. When set, [build] appends `/<token>` to this and ignores
  /// [region]/`projectId` entirely. A trailing slash, if present, is trimmed.
  final String? explicitBaseUrl;

  /// Cloud Functions region used to derive the default base URL. Ignored when
  /// [explicitBaseUrl] is set.
  final String region;

  WebhookUrlBuilder({this.explicitBaseUrl, this.region = _defaultRegion});

  /// Read the build-time `--dart-define` configuration described in the file
  /// header. Falls back to deriving the URL from the project ID at the default
  /// region when nothing is defined.
  factory WebhookUrlBuilder.fromEnvironment() {
    const base = String.fromEnvironment('NOTIFYME_WEBHOOK_BASE_URL');
    const region = String.fromEnvironment(
      'NOTIFYME_FUNCTIONS_REGION',
      defaultValue: _defaultRegion,
    );
    return WebhookUrlBuilder(
      explicitBaseUrl: base.isEmpty ? null : base,
      region: region.isEmpty ? _defaultRegion : region,
    );
  }

  /// The base URL (everything before `/<token>`) for the given [projectId].
  ///
  /// Returns the configured [explicitBaseUrl] verbatim (trailing slash trimmed),
  /// or the derived default
  /// `https://<region>-<projectId>.cloudfunctions.net/webhook`.
  String baseUrlFor(String projectId) {
    final explicit = explicitBaseUrl;
    if (explicit != null) {
      return explicit.endsWith('/')
          ? explicit.substring(0, explicit.length - 1)
          : explicit;
    }
    return 'https://$region-$projectId.cloudfunctions.net/$_functionName';
  }

  /// The full webhook URL a user pastes into integrations: the base plus the
  /// user's `webhookToken` as the final path segment.
  String build({required String projectId, required String token}) {
    return '${baseUrlFor(projectId)}/$token';
  }
}
