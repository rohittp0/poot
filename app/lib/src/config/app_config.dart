import 'local_fallback_defaults.dart';

class AppConfig {
  const AppConfig._();

  static const String localUnlockBaseUrl = String.fromEnvironment(
    'POOT_LOCAL_UNLOCK_BASE_URL',
    defaultValue: LocalFallbackDefaults.baseUrl,
  );

  static const int unlockPulseMs = int.fromEnvironment(
    'POOT_UNLOCK_PULSE_MS',
    defaultValue: LocalFallbackDefaults.unlockPulseMs,
  );

  static const Duration unlockPulseDuration = Duration(
    milliseconds: unlockPulseMs,
  );

  static const Duration localRequestTimeout = Duration(seconds: 6);
  static const Duration localProbeTimeout = Duration(milliseconds: 800);
}
