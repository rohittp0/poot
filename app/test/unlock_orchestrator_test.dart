import 'package:flutter_test/flutter_test.dart';
import 'package:poot/src/models/unlock_result.dart';
import 'package:poot/src/services/local_unlock_service.dart';
import 'package:poot/src/services/settings_service.dart';
import 'package:poot/src/services/unlock_orchestrator.dart';

class FakeSettingsService extends SettingsService {}

class FakeLocalUnlockService extends LocalUnlockService {
  FakeLocalUnlockService({required this.result, this.error})
    : super(settingsService: FakeSettingsService());

  final LocalUnlockResult result;
  final Object? error;
  int calls = 0;

  @override
  Future<LocalUnlockResult> unlock() async {
    calls++;
    if (error != null) {
      throw error!;
    }
    return result;
  }
}

void main() {
  test('returns success with local path when unlock succeeds', () async {
    final FakeLocalUnlockService local = FakeLocalUnlockService(
      result: const LocalUnlockResult(success: true, reason: 'ok'),
    );
    final UnlockOrchestrator orchestrator = UnlockOrchestrator(
      localUnlockService: local,
    );

    final UnlockResult result = await orchestrator.unlock();

    expect(result.success, isTrue);
    expect(result.path, UnlockPath.local);
    expect(local.calls, 1);
  });

  test('returns failure with reason when unlock fails', () async {
    final FakeLocalUnlockService local = FakeLocalUnlockService(
      result: const LocalUnlockResult(success: false, reason: 'invalid_key'),
    );
    final UnlockOrchestrator orchestrator = UnlockOrchestrator(
      localUnlockService: local,
    );

    final UnlockResult result = await orchestrator.unlock();

    expect(result.success, isFalse);
    expect(result.message, contains('invalid_key'));
    expect(local.calls, 1);
  });

  test('returns failure when service throws', () async {
    final FakeLocalUnlockService local = FakeLocalUnlockService(
      result: const LocalUnlockResult(success: false, reason: 'unused'),
      error: StateError('unexpected'),
    );
    final UnlockOrchestrator orchestrator = UnlockOrchestrator(
      localUnlockService: local,
    );

    final UnlockResult result = await orchestrator.unlock();

    expect(result.success, isFalse);
  });

  test('returns canceled immediately when isCancelled is true', () async {
    final FakeLocalUnlockService local = FakeLocalUnlockService(
      result: const LocalUnlockResult(success: true, reason: 'ok'),
    );
    final UnlockOrchestrator orchestrator = UnlockOrchestrator(
      localUnlockService: local,
    );

    final UnlockResult result = await orchestrator.unlock(
      isCancelled: () => true,
    );

    expect(result.success, isFalse);
    expect(result.message, contains('canceled'));
    expect(local.calls, 0);
  });
}
