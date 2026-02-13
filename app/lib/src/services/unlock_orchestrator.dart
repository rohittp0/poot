import '../config/app_config.dart';
import '../models/unlock_result.dart';
import 'cloud_unlock_service.dart';
import 'local_unlock_service.dart';

class UnlockOrchestrator {
  UnlockOrchestrator({
    required CloudUnlockService cloudUnlockService,
    required LocalUnlockService localUnlockService,
  }) : _cloudUnlockService = cloudUnlockService,
       _localUnlockService = localUnlockService;

  final CloudUnlockService _cloudUnlockService;
  final LocalUnlockService _localUnlockService;

  Future<UnlockResult> unlock({
    required String requestedByUid,
    bool Function()? isCancelled,
  }) async {
    bool cancelled() => isCancelled?.call() == true;
    const UnlockResult cancelledResult = UnlockResult(
      success: false,
      path: UnlockPath.none,
      message: 'Unlock canceled.',
    );

    if (cancelled()) {
      return cancelledResult;
    }

    try {
      final CloudUnlockResult cloudResult = await _cloudUnlockService
          .unlockAndAwaitAck(
            lockId: AppConfig.lockId,
            requestedByUid: requestedByUid,
            timeout: AppConfig.cloudAckTimeout,
            isCancelled: isCancelled,
          );

      if (cloudResult.canceled || cancelled()) {
        return cancelledResult;
      }

      if (cloudResult.success) {
        return const UnlockResult(
          success: true,
          path: UnlockPath.cloud,
          message: 'Unlocked through cloud command.',
        );
      }
    } catch (_) {
      if (cancelled()) {
        return cancelledResult;
      }
      // Fall back to local path.
    }

    if (cancelled()) {
      return cancelledResult;
    }

    final LocalUnlockResult local =
        await _localUnlockService.unlockViaAccessPoint();

    if (cancelled()) {
      return cancelledResult;
    }

    if (local.success) {
      return const UnlockResult(
        success: true,
        path: UnlockPath.local,
        message: 'Unlocked through local hotspot fallback.',
      );
    }

    return UnlockResult(
      success: false,
      path: UnlockPath.none,
      message: 'Unlock failed: ${local.reason}',
    );
  }
}
