import 'package:local_auth/local_auth.dart';

class BiometricService {
  BiometricService({LocalAuthentication? localAuth})
    : _localAuth = localAuth ?? LocalAuthentication();

  final LocalAuthentication _localAuth;

  Future<bool> confirmUnlock() async {
    final bool supported =
        await _localAuth.canCheckBiometrics ||
        await _localAuth.isDeviceSupported();
    if (!supported) {
      return false;
    }

    return _localAuth.authenticate(
      localizedReason: 'Authenticate to unlock Poot',
      options: const AuthenticationOptions(
        biometricOnly: true,
        stickyAuth: true,
      ),
    );
  }
}
