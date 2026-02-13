import 'dart:io';

import 'package:flutter/material.dart';

import '../services/auth_service.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.authService});

  final AuthService authService;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  String _error = '';

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = '';
    });

    try {
      await action();
    } catch (error) {
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Poot')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  'Secure lock access',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text('Sign in to unlock Poot from anywhere.'),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed:
                      _busy
                          ? null
                          : () => _run(widget.authService.signInWithGoogle),
                  child: const Text('Continue with Google'),
                ),
                if (Platform.isIOS) ...<Widget>[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed:
                        _busy
                            ? null
                            : () => _run(widget.authService.signInWithApple),
                    child: const Text('Continue with Apple'),
                  ),
                ],
                if (_busy) ...<Widget>[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
                if (_error.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(_error, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
