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

    bool preferDirectLan = false;
    try {
      preferDirectLan = await _localUnlockService.canReachDirectLanUnlock();
    } catch (_) {
      preferDirectLan = false;
    }

    if (preferDirectLan) {
      final LocalUnlockResult localLan;
      try {
        localLan = await _localUnlockService.unlockViaLan();
      } catch (_) {
        preferDirectLan = false;
        return _runCloudThenLocalFallback(
          requestedByUid: requestedByUid,
          preferDirectLan: preferDirectLan,
          cancelled: cancelled,
          cancelledResult: cancelledResult,
          isCancelled: isCancelled,
        );
      }

      if (cancelled()) {
        return cancelledResult;
      }

      if (localLan.success) {
        return const UnlockResult(
          success: true,
          path: UnlockPath.local,
          message: 'Unlocked directly over local Wi-Fi.',
        );
      }
    }

    return _runCloudThenLocalFallback(
      requestedByUid: requestedByUid,
      preferDirectLan: preferDirectLan,
      cancelled: cancelled,
      cancelledResult: cancelledResult,
      isCancelled: isCancelled,
    );
  }

  Future<UnlockResult> _runCloudThenLocalFallback({
    required String requestedByUid,
    required bool preferDirectLan,
    required bool Function() cancelled,
    required UnlockResult cancelledResult,
    required bool Function()? isCancelled,
  }) async {
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

    final LocalUnlockResult local;
    try {
      local =
          preferDirectLan
              ? await _localUnlockService.unlockViaHotspot()
              : await _localUnlockService.unlockLocally();
    } catch (_) {
      return const UnlockResult(
        success: false,
        path: UnlockPath.none,
        message: 'Unlock failed: local_request_failed',
      );
    }

    if (cancelled()) {
      return cancelledResult;
    }

    if (local.success) {
      return const UnlockResult(
        success: true,
        path: UnlockPath.local,
        message: 'Unlocked through local network fallback.',
      );
    }

    return UnlockResult(
      success: false,
      path: UnlockPath.none,
      message: 'Unlock failed: ${local.reason}',
    );
  }
}
