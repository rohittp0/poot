import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../config/app_config.dart';

class AuthService {
  AuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  Stream<User?> authStateChanges() => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  Future<void> signInWithGoogle() async {
    final GoogleSignIn googleSignIn = GoogleSignIn(
      serverClientId:
          AppConfig.googleServerClientId.isEmpty
              ? null
              : AppConfig.googleServerClientId,
    );

    final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
    if (googleUser == null) {
      throw Exception('Google sign-in canceled');
    }

    final GoogleSignInAuthentication googleAuth =
        await googleUser.authentication;

    if (googleAuth.idToken == null && googleAuth.accessToken == null) {
      throw Exception('Google sign-in did not return a usable token.');
    }

    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    await _auth.signInWithCredential(credential);
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

    await _auth.signInWithCredential(authCredential);
  }

  Future<void> signOut() async {
    await Future.wait<void>(<Future<void>>[
      _auth.signOut(),
      GoogleSignIn().signOut(),
    ]);
  }
}
