import '../models/unlock_result.dart';
import 'local_unlock_service.dart';

class UnlockOrchestrator {
  UnlockOrchestrator({required LocalUnlockService localUnlockService})
    : _localUnlockService = localUnlockService;

  final LocalUnlockService _localUnlockService;

  Future<UnlockResult> unlock({bool Function()? isCancelled}) async {
    bool cancelled() => isCancelled?.call() == true;

    const UnlockResult cancelledResult = UnlockResult(
      success: false,
      path: UnlockPath.none,
      message: 'Unlock canceled.',
    );

    if (cancelled()) {
      return cancelledResult;
    }

    final LocalUnlockResult result;
    try {
      result = await _localUnlockService.unlock();
    } catch (_) {
      return const UnlockResult(
        success: false,
        path: UnlockPath.none,
        message: 'Unlock failed unexpectedly.',
      );
    }

    if (cancelled()) {
      return cancelledResult;
    }

    if (result.success) {
      return const UnlockResult(
        success: true,
        path: UnlockPath.local,
        message: 'Unlocked over local Wi-Fi.',
      );
    }

    return UnlockResult(
      success: false,
      path: UnlockPath.none,
      message: 'Unlock failed: ${result.reason}',
    );
  }
}
