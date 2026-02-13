import 'local_fallback_defaults.dart';

class AppConfig {
  const AppConfig._();

  static const String lockId = String.fromEnvironment(
    'POOT_LOCK_ID',
    defaultValue: LocalFallbackDefaults.lockId,
  );

  static const String localUnlockBaseUrl = String.fromEnvironment(
    'POOT_LOCAL_UNLOCK_BASE_URL',
    defaultValue: LocalFallbackDefaults.baseUrl,
  );

  static const Duration cloudAckTimeout = Duration(seconds: 6);
  static const Duration localRequestTimeout = Duration(seconds: 6);

  static const int commandTtlSeconds = 20;
  static const int deviceHeartbeatSeconds = 30;

  static const String googleServerClientId = String.fromEnvironment(
    'POOT_GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '',
  );
}
