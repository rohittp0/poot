import 'biometric_service.dart';
import 'local_unlock_service.dart';
import 'settings_service.dart';
import 'unlock_orchestrator.dart';

class AppServices {
  AppServices._({
    required this.biometricService,
    required this.settingsService,
    required this.localUnlockService,
    required this.unlockOrchestrator,
  });

  factory AppServices.create() {
    final SettingsService settingsService = SettingsService();
    final LocalUnlockService localUnlockService = LocalUnlockService(
      settingsService: settingsService,
    );

    return AppServices._(
      biometricService: BiometricService(),
      settingsService: settingsService,
      localUnlockService: localUnlockService,
      unlockOrchestrator: UnlockOrchestrator(
        localUnlockService: localUnlockService,
      ),
    );
  }

  final BiometricService biometricService;
  final SettingsService settingsService;
  final LocalUnlockService localUnlockService;
  final UnlockOrchestrator unlockOrchestrator;
}
