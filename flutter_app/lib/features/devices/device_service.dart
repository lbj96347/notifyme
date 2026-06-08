// Device registration for push delivery.
//
// Requests notification permission, obtains this device's FCM registration
// token, and upserts a document into the top-level `devices` collection
// (`uid`, `fcmToken`, `platform`, `createdAt`, `updatedAt`) so the webhook
// Cloud Function knows where to push a user's notifications. Keeps the stored
// token fresh by listening for FCM token rotation.
//
// The function side (`firebase_functions/src/messaging.ts`) reads every device
// for a `uid` and prunes any whose token FCM reports as dead, so the contract
// here is just: one document per device, carrying a current `fcmToken`.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class DeviceService {
  DeviceService({FirebaseMessaging? messaging, FirebaseFirestore? firestore})
    : _messaging = messaging ?? FirebaseMessaging.instance,
      _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseMessaging _messaging;
  final FirebaseFirestore _firestore;

  /// Top-level collection holding one document per registered device.
  static const String _collection = 'devices';

  StreamSubscription<String>? _refreshSub;

  /// Request notification permission, register this device's FCM token for
  /// [uid], and start tracking token rotation.
  ///
  /// Safe to call on every sign-in. If the user declines permission we skip
  /// registration (no token to store) and simply return — pushes won't arrive
  /// until they grant it, but the rest of the app keeps working.
  Future<void> register(String uid) async {
    final settings = await _messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return;
    }

    final token = await _getTokenWhenReady();
    if (token != null) {
      await _saveToken(uid: uid, token: token);
    }

    // FCM rotates tokens over time; keep the stored document current. Replacing
    // any prior subscription keeps this idempotent across repeated registers.
    await _refreshSub?.cancel();
    _refreshSub = _messaging.onTokenRefresh.listen((newToken) {
      _saveToken(uid: uid, token: newToken);
    });
  }

  /// Stop listening for token refreshes (call on sign-out / dispose).
  Future<void> dispose() async {
    await _refreshSub?.cancel();
    _refreshSub = null;
  }

  /// On Apple platforms, FCM cannot mint its token until APNs has produced one.
  /// Fresh installs can hit this race immediately after permission is granted,
  /// so wait briefly instead of surfacing `apns-token-not-set` during startup.
  Future<String?> _getTokenWhenReady() async {
    const attempts = 5;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        if (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS) {
          final apnsToken = await _messaging.getAPNSToken();
          if (apnsToken == null) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            continue;
          }
        }
        return await _messaging.getToken();
      } on FirebaseException catch (error) {
        if (error.code != 'apns-token-not-set' || attempt == attempts - 1) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    debugPrint('DeviceService.register skipped: APNS token was not ready.');
    return null;
  }

  /// Upsert the `devices` document for this (uid, token) pair.
  ///
  /// Dedups on `uid + fcmToken` so re-registering the same device updates the
  /// existing document's `updatedAt` rather than piling up duplicates. The
  /// document ID is auto-generated, matching the schema in docs/FIRESTORE_SCHEMA.md.
  Future<void> _saveToken({required String uid, required String token}) async {
    final devices = _firestore.collection(_collection);
    final existing = await devices
        .where('uid', isEqualTo: uid)
        .where('fcmToken', isEqualTo: token)
        .limit(1)
        .get();

    if (existing.docs.isEmpty) {
      await devices.add({
        'uid': uid,
        'fcmToken': token,
        'platform': _platform,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } else {
      await existing.docs.first.reference.update({
        'platform': _platform,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  /// Platform string stored on the device document (`ios` | `android`, with a
  /// sensible fallback for other targets).
  String get _platform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return defaultTargetPlatform.name;
    }
  }
}
