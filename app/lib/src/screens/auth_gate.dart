import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/app_services.dart';
import 'home_screen.dart';
import 'sign_in_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.services});

  final AppServices services;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Future<void> _restoreFuture;

  @override
  void initState() {
    super.initState();
    _restoreFuture = widget.services.authService.restoreSessionIfPossible();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _restoreFuture,
      builder: (BuildContext context, AsyncSnapshot<void> restoreSnapshot) {
        return StreamBuilder<User?>(
          stream: widget.services.authService.authStateChanges(),
          initialData: widget.services.authService.currentUser,
          builder: (BuildContext context, AsyncSnapshot<User?> snapshot) {
            final User? user =
                snapshot.data ?? widget.services.authService.currentUser;
            if (user != null) {
              return HomeScreen(services: widget.services, user: user);
            }

            final bool restoreInProgress =
                restoreSnapshot.connectionState != ConnectionState.done;
            if (restoreInProgress) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            return SignInScreen(authService: widget.services.authService);
          },
        );
      },
    );
  }
}
