import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
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

  Future<bool> canReachDirectLanUnlock() async {
    final LocalUnlockSettings? settings = await _readConfiguredSettings();
    if (settings == null) {
      return false;
    }

    final List<ConnectivityResult> status =
        await _connectivity.checkConnectivity();
    if (!status.contains(ConnectivityResult.wifi)) {
      return false;
    }

    return _isReachable(Uri.parse('${settings.baseUrl}/'));
  }

  Future<LocalUnlockResult> unlockViaLan() async {
    final LocalUnlockSettings? settings = await _readConfiguredSettings();
    if (settings == null) {
      return const LocalUnlockResult(
        success: false,
        reason: 'local_settings_not_configured',
      );
    }

    return _postLocalUnlock(
      uri: Uri.parse('${settings.baseUrl}/api/local-unlock'),
      sharedKey: settings.sharedKey,
    );
  }

  Future<LocalUnlockResult> unlockLocally() async {
    final LocalUnlockSettings? settings = await _readConfiguredSettings();
    if (settings == null) {
      return const LocalUnlockResult(
        success: false,
        reason: 'local_settings_not_configured',
      );
    }

    final LocalUnlockResult lanAttempt = await _postLocalUnlock(
      uri: Uri.parse('${settings.baseUrl}/api/local-unlock'),
      sharedKey: settings.sharedKey,
    );
    if (lanAttempt.success || !_isTransportFailure(lanAttempt.reason)) {
      return lanAttempt;
    }

    await _bestEffortConnect(settings);

    try {
      return await _postLocalUnlock(
        uri: Uri.parse('${settings.hotspotBaseUrl}/api/local-unlock'),
        sharedKey: settings.sharedKey,
      );
    } finally {
      if (Platform.isAndroid) {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      }
    }
  }

  Future<LocalUnlockResult> unlockViaHotspot() async {
    final LocalUnlockSettings? settings = await _readConfiguredSettings();
    if (settings == null) {
      return const LocalUnlockResult(
        success: false,
        reason: 'local_settings_not_configured',
      );
    }

    await _bestEffortConnect(settings);

    try {
      return await _postLocalUnlock(
        uri: Uri.parse('${settings.hotspotBaseUrl}/api/local-unlock'),
        sharedKey: settings.sharedKey,
      );
    } finally {
      if (Platform.isAndroid) {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      }
    }
  }

  Future<LocalUnlockResult> _postLocalUnlock({
    required Uri uri,
    required String sharedKey,
  }) async {
    try {
      final http.Response response = await _httpClient
          .post(
            uri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, Object>{'key': sharedKey}),
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

  bool _isTransportFailure(String reason) {
    return reason == 'local_timeout' || reason == 'local_request_failed';
  }

  Future<LocalUnlockSettings?> _readConfiguredSettings() async {
    final LocalUnlockSettings settings = await _settingsService.readSettings();
    if (!settings.isConfigured) {
      return null;
    }
    return settings;
  }

  Future<bool> _isReachable(Uri uri) async {
    try {
      final http.Response response = await _httpClient
          .get(uri)
          .timeout(AppConfig.localProbeTimeout);
      return response.statusCode == 200 &&
          response.body.trim() == 'Poot lock online';
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
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
}
