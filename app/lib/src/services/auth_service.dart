import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../config/app_config.dart';

class GoogleAuthSession {
  const GoogleAuthSession({this.accessToken, this.idToken});

  final String? accessToken;
  final String? idToken;

  bool get hasUsableToken => accessToken != null || idToken != null;
}

abstract class AuthBackend {
  Stream<User?> authStateChanges();
  User? get currentUser;
  Future<void> signInWithCredential(AuthCredential credential);
  Future<void> signOut();
}

class FirebaseAuthBackend implements AuthBackend {
  FirebaseAuthBackend({FirebaseAuth? auth})
    : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  @override
  Stream<User?> authStateChanges() => _auth.authStateChanges();

  @override
  User? get currentUser => _auth.currentUser;

  @override
  Future<void> signInWithCredential(AuthCredential credential) async {
    await _auth.signInWithCredential(credential);
  }

  @override
  Future<void> signOut() => _auth.signOut();
}

abstract class GoogleAuthBackend {
  Future<GoogleAuthSession?> signIn();
  Future<GoogleAuthSession?> signInSilently();
  Future<void> signOut();
}

class GoogleSignInBackend implements GoogleAuthBackend {
  GoogleSignInBackend({GoogleSignIn? googleSignIn})
    : _googleSignIn =
          googleSignIn ??
          GoogleSignIn(
            serverClientId:
                AppConfig.googleServerClientId.isEmpty
                    ? null
                    : AppConfig.googleServerClientId,
          );

  final GoogleSignIn _googleSignIn;

  @override
  Future<GoogleAuthSession?> signIn() async {
    final GoogleSignInAccount? account = await _googleSignIn.signIn();
    return _readSession(account);
  }

  @override
  Future<GoogleAuthSession?> signInSilently() async {
    final GoogleSignInAccount? account = await _googleSignIn.signInSilently();
    return _readSession(account);
  }

  @override
  Future<void> signOut() async {
    await _googleSignIn.signOut();
  }

  Future<GoogleAuthSession?> _readSession(GoogleSignInAccount? account) async {
    if (account == null) {
      return null;
    }

    final GoogleSignInAuthentication auth = await account.authentication;
    return GoogleAuthSession(
      accessToken: auth.accessToken,
      idToken: auth.idToken,
    );
  }
}

class AuthService {
  AuthService({AuthBackend? authBackend, GoogleAuthBackend? googleAuthBackend})
    : _authBackend = authBackend ?? FirebaseAuthBackend(),
      _googleAuthBackend = googleAuthBackend ?? GoogleSignInBackend();

  final AuthBackend _authBackend;
  final GoogleAuthBackend _googleAuthBackend;
  Future<void>? _restoreFuture;

  Stream<User?> authStateChanges() => _authBackend.authStateChanges();

  User? get currentUser => _authBackend.currentUser;

  Future<void> signInWithGoogle() async {
    final GoogleAuthSession? session = await _googleAuthBackend.signIn();
    if (session == null) {
      throw Exception('Google sign-in canceled');
    }

    if (!session.hasUsableToken) {
      throw Exception('Google sign-in did not return a usable token.');
    }

    final credential = GoogleAuthProvider.credential(
      accessToken: session.accessToken,
      idToken: session.idToken,
    );

    await _authBackend.signInWithCredential(credential);
  }

  Future<void> restoreSessionIfPossible() async {
    if (currentUser != null) {
      return;
    }

    if (_restoreFuture != null) {
      return _restoreFuture;
    }

    _restoreFuture = _restoreSession();
    try {
      await _restoreFuture;
    } finally {
      _restoreFuture = null;
    }
  }

  Future<void> _restoreSession() async {
    try {
      final GoogleAuthSession? session =
          await _googleAuthBackend.signInSilently();
      if (session == null || !session.hasUsableToken) {
        return;
      }
      if (currentUser != null) {
        return;
      }

      final credential = GoogleAuthProvider.credential(
        accessToken: session.accessToken,
        idToken: session.idToken,
      );
      await _authBackend.signInWithCredential(credential);
    } catch (error) {
      debugPrint('Silent sign-in restore failed: $error');
    }
  }

  Future<void> signInWithApple() async {
    if (!Platform.isIOS) {
      throw Exception('Apple sign-in is available on iOS only in this build');
    }

    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: <AppleIDAuthorizationScopes>[
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );

    final oauthProvider = OAuthProvider('apple.com');
    final authCredential = oauthProvider.credential(
      idToken: credential.identityToken,
      accessToken: credential.authorizationCode,
    );

    await _authBackend.signInWithCredential(authCredential);
  }

  Future<void> signOut() async {
    await Future.wait<void>(<Future<void>>[
      _authBackend.signOut(),
      _googleAuthBackend.signOut(),
    ]);
  }
}
