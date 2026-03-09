import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poot/src/services/auth_service.dart';

class FakeAuthBackend implements AuthBackend {
  FakeAuthBackend({this.currentUserValue});

  User? currentUserValue;
  int signInWithCredentialCalls = 0;
  int signOutCalls = 0;
  AuthCredential? lastCredential;

  @override
  Stream<User?> authStateChanges() => Stream<User?>.value(currentUserValue);

  @override
  User? get currentUser => currentUserValue;

  @override
  Future<void> signInWithCredential(AuthCredential credential) async {
    signInWithCredentialCalls++;
    lastCredential = credential;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }
}

class FakeGoogleAuthBackend implements GoogleAuthBackend {
  FakeGoogleAuthBackend({
    this.interactiveSession,
    this.silentSession,
    this.silentError,
  });

  final GoogleAuthSession? interactiveSession;
  final GoogleAuthSession? silentSession;
  final Object? silentError;

  int signInCalls = 0;
  int signInSilentlyCalls = 0;
  int signOutCalls = 0;

  @override
  Future<GoogleAuthSession?> signIn() async {
    signInCalls++;
    return interactiveSession;
  }

  @override
  Future<GoogleAuthSession?> signInSilently() async {
    signInSilentlyCalls++;
    if (silentError != null) {
      throw silentError!;
    }
    return silentSession;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }
}

void main() {
  test(
    'restoreSessionIfPossible signs in with a silent Google session',
    () async {
      final FakeAuthBackend authBackend = FakeAuthBackend();
      final FakeGoogleAuthBackend googleAuthBackend = FakeGoogleAuthBackend(
        silentSession: const GoogleAuthSession(accessToken: 'access-token'),
      );
      final AuthService service = AuthService(
        authBackend: authBackend,
        googleAuthBackend: googleAuthBackend,
      );

      await service.restoreSessionIfPossible();

      expect(googleAuthBackend.signInSilentlyCalls, 1);
      expect(authBackend.signInWithCredentialCalls, 1);
      expect(authBackend.lastCredential, isNotNull);
    },
  );

  test('restoreSessionIfPossible ignores silent restore failures', () async {
    final FakeAuthBackend authBackend = FakeAuthBackend();
    final FakeGoogleAuthBackend googleAuthBackend = FakeGoogleAuthBackend(
      silentError: StateError('restore failed'),
    );
    final AuthService service = AuthService(
      authBackend: authBackend,
      googleAuthBackend: googleAuthBackend,
    );

    await service.restoreSessionIfPossible();

    expect(googleAuthBackend.signInSilentlyCalls, 1);
    expect(authBackend.signInWithCredentialCalls, 0);
  });

  test('signOut signs out both Firebase and Google backends', () async {
    final FakeAuthBackend authBackend = FakeAuthBackend();
    final FakeGoogleAuthBackend googleAuthBackend = FakeGoogleAuthBackend();
    final AuthService service = AuthService(
      authBackend: authBackend,
      googleAuthBackend: googleAuthBackend,
    );

    await service.signOut();

    expect(authBackend.signOutCalls, 1);
    expect(googleAuthBackend.signOutCalls, 1);
  });
}
