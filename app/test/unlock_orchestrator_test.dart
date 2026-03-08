import 'package:flutter_test/flutter_test.dart';
import 'package:poot/src/models/unlock_result.dart';
import 'package:poot/src/services/cloud_unlock_service.dart';
import 'package:poot/src/services/local_unlock_service.dart';
import 'package:poot/src/services/settings_service.dart';
import 'package:poot/src/services/unlock_orchestrator.dart';

class FakeSettingsService extends SettingsService {}

class FakeLocalUnlockService extends LocalUnlockService {
  FakeLocalUnlockService({
    required this.canReachLan,
    required this.lanResult,
    required this.localResult,
    required this.hotspotResult,
  }) : super(settingsService: FakeSettingsService());

  final bool canReachLan;
  final LocalUnlockResult lanResult;
  final LocalUnlockResult localResult;
  final LocalUnlockResult hotspotResult;

  int canReachLanCalls = 0;
  int unlockViaLanCalls = 0;
  int unlockLocallyCalls = 0;
  int unlockViaHotspotCalls = 0;

  @override
  Future<bool> canReachDirectLanUnlock() async {
    canReachLanCalls++;
    return canReachLan;
  }

  @override
  Future<LocalUnlockResult> unlockViaLan() async {
    unlockViaLanCalls++;
    return lanResult;
  }

  @override
  Future<LocalUnlockResult> unlockLocally() async {
    unlockLocallyCalls++;
    return localResult;
  }

  @override
  Future<LocalUnlockResult> unlockViaHotspot() async {
    unlockViaHotspotCalls++;
    return hotspotResult;
  }
}

class FakeCloudUnlockService extends CloudUnlockService {
  FakeCloudUnlockService(this.result);

  final CloudUnlockResult result;
  int calls = 0;

  @override
  Future<CloudUnlockResult> unlockAndAwaitAck({
    required String lockId,
    required String requestedByUid,
    required Duration timeout,
    bool Function()? isCancelled,
  }) async {
    calls++;
    return result;
  }
}

void main() {
  test('prefers direct LAN unlock when it is reachable', () async {
    final FakeLocalUnlockService local = FakeLocalUnlockService(
      canReachLan: true,
      lanResult: const LocalUnlockResult(success: true, reason: 'ok'),
      localResult: const LocalUnlockResult(success: false, reason: 'unused'),
      hotspotResult: const LocalUnlockResult(success: false, reason: 'unused'),
    );
    final FakeCloudUnlockService cloud = FakeCloudUnlockService(
      const CloudUnlockResult(
        success: false,
        commandId: '',
        reason: 'unused',
        timedOut: false,
        canceled: false,
      ),
    );
    final UnlockOrchestrator orchestrator = UnlockOrchestrator(
      cloudUnlockService: cloud,
      localUnlockService: local,
    );

    final UnlockResult result = await orchestrator.unlock(
      requestedByUid: 'user-1',
    );

    expect(result.success, isTrue);
    expect(result.path, UnlockPath.local);
    expect(result.message, 'Unlocked directly over local Wi-Fi.');
    expect(local.canReachLanCalls, 1);
    expect(local.unlockViaLanCalls, 1);
    expect(cloud.calls, 0);
    expect(local.unlockViaHotspotCalls, 0);
  });

  test('falls back to cloud when direct LAN unlock fails', () async {
    final FakeLocalUnlockService local = FakeLocalUnlockService(
      canReachLan: true,
      lanResult: const LocalUnlockResult(success: false, reason: 'invalid_key'),
      localResult: const LocalUnlockResult(success: false, reason: 'unused'),
      hotspotResult: const LocalUnlockResult(success: false, reason: 'unused'),
    );
    final FakeCloudUnlockService cloud = FakeCloudUnlockService(
      const CloudUnlockResult(
        success: true,
        commandId: 'cmd-1',
        reason: 'ok',
        timedOut: false,
        canceled: false,
      ),
    );
    final UnlockOrchestrator orchestrator = UnlockOrchestrator(
      cloudUnlockService: cloud,
      localUnlockService: local,
    );

    final UnlockResult result = await orchestrator.unlock(
      requestedByUid: 'user-1',
    );

    expect(result.success, isTrue);
    expect(result.path, UnlockPath.cloud);
    expect(local.unlockViaLanCalls, 1);
    expect(cloud.calls, 1);
    expect(local.unlockViaHotspotCalls, 0);
  });

  test(
    'uses hotspot fallback after cloud failure when LAN was tried first',
    () async {
      final FakeLocalUnlockService local = FakeLocalUnlockService(
        canReachLan: true,
        lanResult: const LocalUnlockResult(
          success: false,
          reason: 'local_request_failed',
        ),
        localResult: const LocalUnlockResult(success: false, reason: 'unused'),
        hotspotResult: const LocalUnlockResult(success: true, reason: 'ok'),
      );
      final FakeCloudUnlockService cloud = FakeCloudUnlockService(
        const CloudUnlockResult(
          success: false,
          commandId: 'cmd-1',
          reason: 'cloud_ack_timeout',
          timedOut: true,
          canceled: false,
        ),
      );
      final UnlockOrchestrator orchestrator = UnlockOrchestrator(
        cloudUnlockService: cloud,
        localUnlockService: local,
      );

      final UnlockResult result = await orchestrator.unlock(
        requestedByUid: 'user-1',
      );

      expect(result.success, isTrue);
      expect(result.path, UnlockPath.local);
      expect(local.unlockViaLanCalls, 1);
      expect(cloud.calls, 1);
      expect(local.unlockViaHotspotCalls, 1);
      expect(local.unlockLocallyCalls, 0);
    },
  );
}
