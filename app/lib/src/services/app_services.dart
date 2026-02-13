import 'admin_users_service.dart';
import 'auth_service.dart';
import 'biometric_service.dart';
import 'cloud_unlock_service.dart';
import 'lock_state_service.dart';
import 'local_unlock_service.dart';
import 'settings_service.dart';
import 'unlock_orchestrator.dart';

class AppServices {
  AppServices._({
    required this.authService,
    required this.biometricService,
    required this.settingsService,
    required this.cloudUnlockService,
    required this.localUnlockService,
    required this.unlockOrchestrator,
    required this.adminUsersService,
    required this.lockStateService,
  });

  factory AppServices.create() {
    final SettingsService settingsService = SettingsService();
    final CloudUnlockService cloudUnlockService = CloudUnlockService();
    final LockStateService lockStateService = LockStateService();
    final LocalUnlockService localUnlockService = LocalUnlockService(
      settingsService: settingsService,
    );

    return AppServices._(
      authService: AuthService(),
      biometricService: BiometricService(),
      settingsService: settingsService,
      cloudUnlockService: cloudUnlockService,
      lockStateService: lockStateService,
      localUnlockService: localUnlockService,
      unlockOrchestrator: UnlockOrchestrator(
        cloudUnlockService: cloudUnlockService,
        localUnlockService: localUnlockService,
      ),
      adminUsersService: AdminUsersService(),
    );
  }

  final AuthService authService;
  final BiometricService biometricService;
  final SettingsService settingsService;
  final CloudUnlockService cloudUnlockService;
  final LockStateService lockStateService;
  final LocalUnlockService localUnlockService;
  final UnlockOrchestrator unlockOrchestrator;
  final AdminUsersService adminUsersService;
}
