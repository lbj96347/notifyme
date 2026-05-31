// Webhook token generation (client side).
//
// Each user gets a personal webhook URL: `POST /webhook/{webhookToken}`. The
// token is the routing key the Cloud Function resolves back to a `uid`
// (`where("webhookToken", "==", token)` — see firebase_functions/src/token.ts).
//
// MVP security posture: the token is an *unguessable routing key*, not a
// verified secret. Security rests entirely on its entropy, so it MUST come from
// a cryptographically secure RNG — never `Random()`.
//
// The output must match what the function accepts: url-safe base64 with no
// padding (`[A-Za-z0-9_-]+`), so it drops straight into a URL path segment.
// 32 bytes = 256 bits of entropy, the same width the function mints server-side.

import 'dart:convert';
import 'dart:math';

/// Number of random bytes behind a token. 32 bytes = 256 bits, rendered as 43
/// url-safe base64 characters — infeasible to guess. Mirrors `TOKEN_BYTES` in
/// firebase_functions/src/token.ts.
const int _tokenBytes = 32;

/// Mint a fresh, unguessable webhook token.
///
/// Uses [Random.secure] (a cryptographically secure source). Returns url-safe
/// base64 with the `=` padding stripped, matching the function's
/// `randomBytes(32).toString("base64url")` output and its token pattern.
String generateWebhookToken() {
  final rng = Random.secure();
  final bytes = List<int>.generate(_tokenBytes, (_) => rng.nextInt(256));
  // base64Url uses the url-safe alphabet (- and _); strip padding so the token
  // is a clean path segment that satisfies the function's `[A-Za-z0-9_-]+`.
  return base64Url.encode(bytes).replaceAll('=', '');
}
