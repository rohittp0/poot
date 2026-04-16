import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    http.Client? httpClient,
  }) : _settingsService = settingsService,
       _httpClient = httpClient ?? http.Client();

  final SettingsService _settingsService;
  final http.Client _httpClient;

  Future<bool> canReachDirectLanUnlock() async {
    try {
      final LocalUnlockSettings? settings = await _readConfiguredSettings();
      if (settings == null) {
        return false;
      }
      return _isReachable(Uri.parse('${settings.baseUrl}/'));
    } catch (_) {
      return false;
    }
  }

  Future<LocalUnlockResult> unlockViaLan() async {
    try {
      final LocalUnlockSettings? settings = await _readConfiguredSettings();
      if (settings == null) {
        return const LocalUnlockResult(
          success: false,
          reason: 'local_settings_not_configured',
        );
      }
      return _requestLocalUnlock(
        uri: Uri.parse('${settings.baseUrl}/api/local-unlock'),
        sharedKey: settings.sharedKey,
      );
    } catch (_) {
      return const LocalUnlockResult(
        success: false,
        reason: 'local_request_failed',
      );
    }
  }

  // Checks reachability, connects to home WiFi if needed, then unlocks.
  Future<LocalUnlockResult> unlock() async {
    try {
      final LocalUnlockSettings? settings = await _readConfiguredSettings();
      if (settings == null) {
        return const LocalUnlockResult(
          success: false,
          reason: 'local_settings_not_configured',
        );
      }

      final bool reachable =
          await _isReachable(Uri.parse('${settings.baseUrl}/'));
      if (!reachable) {
        await _connectToHomeWifi(settings);
      }

      return _requestLocalUnlock(
        uri: Uri.parse('${settings.baseUrl}/api/local-unlock'),
        sharedKey: settings.sharedKey,
      );
    } catch (_) {
      return const LocalUnlockResult(
        success: false,
        reason: 'local_request_failed',
      );
    }
  }

  Future<LocalUnlockResult> _requestLocalUnlock({
    required Uri uri,
    required String sharedKey,
  }) async {
    try {
      final Uri requestUri = uri.replace(
        queryParameters: <String, String>{'key': sharedKey},
      );
      final http.Response response = await _httpClient
          .get(requestUri)
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

  Future<void> _connectToHomeWifi(LocalUnlockSettings settings) async {
    if (settings.homeWifiSsid.isEmpty) {
      return;
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }

    try {
      await WiFiForIoTPlugin.setEnabled(true, shouldOpenSettings: false);
    } catch (_) {}

    try {
      await WiFiForIoTPlugin.connect(
        settings.homeWifiSsid,
        password: settings.homeWifiPassword,
        security: NetworkSecurity.WPA,
        joinOnce: true,
        withInternet: true,
      );
    } catch (_) {
      // iOS may require user confirmation via system prompt.
    }

    await Future<void>.delayed(const Duration(seconds: 2));
  }
}
