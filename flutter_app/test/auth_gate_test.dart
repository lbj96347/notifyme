// Widget tests for [AuthGate].
//
// These stay deliberately small: they exercise the two states that don't pull
// in Firebase-backed screens — the initial loading spinner and the signed-out
// [AuthScreen]. The signed-in branch builds [HomePage], which wires up
// Firestore/Messaging and isn't worth faking here.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/app/auth_gate.dart';
import 'package:notifyme/features/auth/auth_screen.dart';
import 'package:notifyme/features/auth/auth_service.dart';

/// Stand-ins that are stored but never used: the fake [AuthService] overrides
/// the only method [AuthGate] calls, so the real Firebase instances are never
/// touched. They exist purely to satisfy the [AuthService] constructor without
/// initializing Firebase.
class _UnusedFirebaseAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FirebaseAuth should not be used in tests');
}

class _UnusedFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Firestore should not be used in tests');
}

class _FakeAuthService extends AuthService {
  _FakeAuthService(this._stream)
    : super(auth: _UnusedFirebaseAuth(), firestore: _UnusedFirestore());

  final Stream<User?> _stream;

  @override
  Stream<User?> authStateChanges() => _stream;
}

void main() {
  testWidgets('shows a spinner while the first auth state is loading', (
    tester,
  ) async {
    // A stream that never emits keeps the StreamBuilder in the waiting state.
    final controller = StreamController<User?>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: AuthGate(authService: _FakeAuthService(controller.stream)),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
  });

  testWidgets('shows the AuthScreen when no user is signed in', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AuthGate(
          authService: _FakeAuthService(Stream<User?>.value(null)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
