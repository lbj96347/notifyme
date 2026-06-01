// Authentication service — a thin wrapper over Firebase Auth.
//
// Keeps Firebase APIs out of the widget layer so screens depend on a small,
// testable surface. After every successful sign-in (or sign-up) we ensure the
// user's `users/{uid}` document exists in Firestore (uid, email, createdAt, and
// a generated webhookToken) per the data model in CLAUDE.md, so the rest of the
// app — and the webhook Cloud Function — can rely on that record existing.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'webhook_token.dart';

/// Raised for auth failures with a message that's safe to show to users.
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}

class AuthService {
  AuthService({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  /// Emits the signed-in user, or null when signed out. Drives [AuthGate].
  Stream<User?> authStateChanges() => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  /// Sign in an existing user with email + password.
  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      await ensureUserDocument(credential.user);
      return credential;
    } on FirebaseAuthException catch (e) {
      throw AuthException(_messageFor(e));
    } on FirebaseException catch (e) {
      // The Firestore profile write failed (e.g. rules not deployed, offline).
      // Auth itself succeeded, so don't masquerade as a credential error —
      // surface a distinct, actionable message instead of silently dropping it.
      throw AuthException(_profileMessageFor(e));
    }
  }

  /// Create a new account, then provision the `users/{uid}` profile document.
  Future<UserCredential> signUp({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      await ensureUserDocument(credential.user);
      return credential;
    } on FirebaseAuthException catch (e) {
      throw AuthException(_messageFor(e));
    } on FirebaseException catch (e) {
      throw AuthException(_profileMessageFor(e));
    }
  }

  /// Create or update `users/{uid}` so the profile exists with a webhook token.
  ///
  /// Idempotent and safe to call on every sign-in: it fills in `uid`, `email`,
  /// and a `createdAt` server timestamp the first time, and mints a
  /// [generateWebhookToken] only when one isn't already stored — so an existing
  /// user's webhook URL never changes out from under them. The read + write run
  /// in a transaction so two devices signing in at once can't race to two
  /// different tokens.
  Future<void> ensureUserDocument(User? user) async {
    if (user == null) return;

    final ref = _firestore.collection('users').doc(user.uid);
    await _firestore.runTransaction((tx) async {
      final snapshot = await tx.get(ref);
      final data = <String, dynamic>{
        'uid': user.uid,
        'email': user.email,
      };

      if (!snapshot.exists) {
        // First sign-in: stamp creation time and mint the webhook token.
        data['createdAt'] = FieldValue.serverTimestamp();
        data['webhookToken'] = generateWebhookToken();
      } else if (snapshot.data()?['webhookToken'] is! String) {
        // Existing profile that predates the token (or lost it): backfill one.
        data['webhookToken'] = generateWebhookToken();
      }

      tx.set(ref, data, SetOptions(merge: true));
    });
  }

  Future<void> signOut() => _auth.signOut();

  /// Map Firebase error codes to friendly, user-facing copy.
  String _messageFor(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'That email address looks invalid.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'An account already exists for that email.';
      case 'weak-password':
        return 'Password is too weak (use at least 6 characters).';
      case 'network-request-failed':
        return 'Network error. Check your connection and try again.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again.';
      default:
        return e.message ?? 'Authentication failed. Please try again.';
    }
  }

  /// Message for a failure to write the `users/{uid}` profile after auth
  /// succeeded. `permission-denied` almost always means the Firestore security
  /// rules haven't been deployed to this project yet.
  String _profileMessageFor(FirebaseException e) {
    if (e.code == 'permission-denied') {
      return 'Signed in, but could not set up your profile. Deploy the '
          'Firestore security rules to your project, then try again.';
    }
    return 'Signed in, but could not set up your profile. Check your '
        'connection and try again.';
  }
}
