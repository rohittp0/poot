import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:wifi_iot/wifi_iot.dart';

import '../config/app_config.dart';
import '../models/local_unlock_settings.dart';
import 'settings_service.dart';

class LocalUnlockResult {
  const LocalUnlockResult({required this.success, required this.reason});

  final bool success;
  final String reason;
}

class _LocalTimeSyncResult {
  const _LocalTimeSyncResult({
    required this.success,
    this.ts,
    required this.reason,
  });

  final bool success;
  final int? ts;
  final String reason;
}

class LocalUnlockService {
  LocalUnlockService({
    required SettingsService settingsService,
    Connectivity? connectivity,
    http.Client? httpClient,
  }) : _settingsService = settingsService,
       _connectivity = connectivity ?? Connectivity(),
       _httpClient = httpClient ?? http.Client();

  final SettingsService _settingsService;
  final Connectivity _connectivity;
  final http.Client _httpClient;

  Future<LocalUnlockResult> unlockViaAccessPoint() async {
    final LocalUnlockSettings settings = await _settingsService.readSettings();
    if (!settings.isConfigured) {
      return const LocalUnlockResult(
        success: false,
        reason: 'local_settings_not_configured',
      );
    }

    await _bestEffortConnect(settings);

    final Uri uri = Uri.parse('${settings.baseUrl}/api/local-unlock');
    final Uri localTimeUri = Uri.parse('${settings.baseUrl}/api/local-time');

    try {
      final int firstTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final LocalUnlockResult firstAttempt = await _postLocalUnlock(
        uri: uri,
        ts: firstTs,
        sig: _signTimestamp(settings.sharedSecret, firstTs),
      );

      if (firstAttempt.success ||
          firstAttempt.reason != 'timestamp_out_of_window') {
        return firstAttempt;
      }

      final _LocalTimeSyncResult localTime = await _fetchLocalTime(
        uri: localTimeUri,
      );
      if (!localTime.success || localTime.ts == null) {
        return LocalUnlockResult(success: false, reason: localTime.reason);
      }

      final LocalUnlockResult retryAttempt = await _postLocalUnlock(
        uri: uri,
        ts: localTime.ts!,
        sig: _signTimestamp(settings.sharedSecret, localTime.ts!),
      );
      if (!retryAttempt.success &&
          retryAttempt.reason == 'timestamp_out_of_window') {
        return const LocalUnlockResult(
          success: false,
          reason: 'local_time_sync_failed',
        );
      }
      return retryAttempt;
    } finally {
      if (Platform.isAndroid) {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      }
    }
  }

  Future<LocalUnlockResult> _postLocalUnlock({
    required Uri uri,
    required int ts,
    required String sig,
  }) async {
    try {
      final http.Response response = await _httpClient
          .post(
            uri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, Object>{'ts': ts, 'sig': sig}),
          )
          .timeout(AppConfig.localRequestTimeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const LocalUnlockResult(success: true, reason: 'ok');
      }

      try {
        final Map<String, dynamic> body =
            jsonDecode(response.body) as Map<String, dynamic>;
        return LocalUnlockResult(
          success: false,
          reason: (body['code'] ?? 'local_unlock_denied').toString(),
        );
      } catch (_) {
        return const LocalUnlockResult(
          success: false,
          reason: 'local_unlock_denied',
        );
      }
    } on TimeoutException {
      return const LocalUnlockResult(success: false, reason: 'local_timeout');
    } catch (_) {
      return const LocalUnlockResult(
        success: false,
        reason: 'local_request_failed',
      );
    }
  }

  Future<_LocalTimeSyncResult> _fetchLocalTime({required Uri uri}) async {
    try {
      final http.Response response = await _httpClient
          .get(uri)
          .timeout(AppConfig.localRequestTimeout);

      Map<String, dynamic>? body;
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        body = null;
      }

      if (response.statusCode >= 200 &&
          response.statusCode < 300 &&
          body != null &&
          body['ok'] == true &&
          body['ts'] is num) {
        return _LocalTimeSyncResult(
          success: true,
          ts: (body['ts'] as num).toInt(),
          reason: 'ok',
        );
      }

      if (response.statusCode == 503 &&
          body != null &&
          (body['code'] ?? '').toString() == 'no_clock') {
        return const _LocalTimeSyncResult(
          success: false,
          reason: 'no_clock',
        );
      }

      return const _LocalTimeSyncResult(
        success: false,
        reason: 'local_time_sync_failed',
      );
    } catch (_) {
      return const _LocalTimeSyncResult(
        success: false,
        reason: 'local_time_sync_failed',
      );
    }
  }

  Future<void> _bestEffortConnect(LocalUnlockSettings settings) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }

    try {
      await WiFiForIoTPlugin.setEnabled(true, shouldOpenSettings: false);
    } catch (_) {
      // iOS may block this call; continue with best effort.
    }

    try {
      await WiFiForIoTPlugin.connect(
        settings.espSsid,
        password: settings.espPassword,
        security: NetworkSecurity.WPA,
        joinOnce: true,
        withInternet: false,
      );
    } catch (_) {
      // iOS can require user confirmation via system prompt.
    }

    if (Platform.isAndroid) {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(true);
      } catch (_) {
        // Continue even if network binding fails.
      }
    }

    await Future<void>.delayed(const Duration(seconds: 2));

    final List<ConnectivityResult> status =
        await _connectivity.checkConnectivity();
    if (!status.contains(ConnectivityResult.wifi)) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  String _signTimestamp(String sharedSecret, int ts) {
    final Hmac hmac = Hmac(sha256, utf8.encode(sharedSecret));
    return hmac.convert(utf8.encode(ts.toString())).toString();
  }
}
