import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import '../config/app_config.dart';

class CloudUnlockResult {
  const CloudUnlockResult({
    required this.success,
    required this.commandId,
    required this.reason,
    required this.timedOut,
    required this.canceled,
  });

  final bool success;
  final String commandId;
  final String reason;
  final bool timedOut;
  final bool canceled;
}

class CloudUnlockService {
  CloudUnlockService({FirebaseDatabase? database})
    : _database = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _database;

  Future<CloudUnlockResult> unlockAndAwaitAck({
    required String lockId,
    required String requestedByUid,
    required Duration timeout,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() == true) {
      return const CloudUnlockResult(
        success: false,
        commandId: '',
        reason: 'canceled',
        timedOut: false,
        canceled: true,
      );
    }

    final DatabaseReference commandsRef = _database.ref(
      'locks/$lockId/commands',
    );
    final DatabaseReference auditRef = _database.ref('locks/$lockId/audit');

    final String commandId =
        commandsRef.push().key ??
        'cmd_${DateTime.now().millisecondsSinceEpoch}';

    final Completer<CloudUnlockResult> completer =
        Completer<CloudUnlockResult>();
    Timer? cancelPoller;

    late final StreamSubscription<DatabaseEvent> sub;
    sub = auditRef.limitToLast(40).onChildAdded.listen((DatabaseEvent event) {
      final Object? raw = event.snapshot.value;
      if (raw is! Map<Object?, Object?>) {
        return;
      }

      if ((raw['commandId'] ?? '').toString() != commandId) {
        return;
      }

      final String result = (raw['result'] ?? 'unknown').toString();
      final String reason = (raw['reason'] ?? 'unknown').toString();
      if (!completer.isCompleted) {
        completer.complete(
          CloudUnlockResult(
            success: result == 'success',
            commandId: commandId,
            reason: reason,
            timedOut: false,
            canceled: false,
          ),
        );
      }
    });

    if (isCancelled != null) {
      cancelPoller = Timer.periodic(const Duration(milliseconds: 120), (
        Timer timer,
      ) {
        if (isCancelled() && !completer.isCompleted) {
          completer.complete(
            CloudUnlockResult(
              success: false,
              commandId: commandId,
              reason: 'canceled',
              timedOut: false,
              canceled: true,
            ),
          );
        }
      });
    }

    try {
      final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await commandsRef.child(commandId).set(<String, Object>{
        'type': 'unlock',
        'requestedByUid': requestedByUid,
        'createdAt': now,
        'expiresAt': now + AppConfig.commandTtlSeconds,
        'channel': 'mobile',
      });

      if (isCancelled?.call() == true) {
        return CloudUnlockResult(
          success: false,
          commandId: commandId,
          reason: 'canceled',
          timedOut: false,
          canceled: true,
        );
      }

      return await completer.future.timeout(
        timeout,
        onTimeout:
            () => CloudUnlockResult(
              success: false,
              commandId: commandId,
              reason: 'cloud_ack_timeout',
              timedOut: true,
              canceled: false,
            ),
      );
    } on TimeoutException {
      return const CloudUnlockResult(
        success: false,
        commandId: '',
        reason: 'cloud_ack_timeout',
        timedOut: true,
        canceled: false,
      );
    } finally {
      cancelPoller?.cancel();
      await sub.cancel();
    }
  }
}
