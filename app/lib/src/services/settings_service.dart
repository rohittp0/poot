import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/local_fallback_defaults.dart';
import '../models/local_unlock_settings.dart';

class SettingsService {
  SettingsService({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secureStorage;

  static const String _ssidKey = 'esp_ssid';
  static const String _passwordKey = 'esp_password';
  static const String _baseUrlKey = 'esp_base_url';
  static const String _sharedKeyStorageKey = 'shared_key';
  static const String _legacySharedSecretKey = 'shared_hmac_secret';
  static const String _manualOverridesKey = 'local_settings_manual_overrides';

  String _normalize(String? value) => value?.trim() ?? '';

  String _preferStored(String? stored, String fallback) {
    final String normalized = _normalize(stored);
    if (normalized.isNotEmpty) {
      return normalized;
    }
    return fallback;
  }

  Future<void> _persistSettings(LocalUnlockSettings settings) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ssidKey, settings.espSsid.trim());
    await prefs.setString(_passwordKey, settings.espPassword.trim());
    await prefs.setString(_baseUrlKey, settings.baseUrl.trim());
    await _secureStorage.write(
      key: _sharedKeyStorageKey,
      value: settings.sharedKey.trim(),
    );
    await _secureStorage.delete(key: _legacySharedSecretKey);
  }

  Future<LocalUnlockSettings> readSettings() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool hasManualOverrides = prefs.getBool(_manualOverridesKey) ?? false;

    final LocalUnlockSettings generatedDefaults = LocalUnlockSettings(
      espSsid: LocalFallbackDefaults.espSsid,
      espPassword: LocalFallbackDefaults.espPassword,
      sharedKey: LocalFallbackDefaults.sharedKey,
      baseUrl: LocalFallbackDefaults.baseUrl,
      hotspotBaseUrl: LocalFallbackDefaults.hotspotBaseUrl,
    );

    if (!hasManualOverrides) {
      await _persistSettings(generatedDefaults);
      return generatedDefaults;
    }

    final String? sharedKey =
        await _secureStorage.read(key: _sharedKeyStorageKey) ??
        await _secureStorage.read(key: _legacySharedSecretKey);

    return LocalUnlockSettings(
      espSsid: _preferStored(
        prefs.getString(_ssidKey),
        generatedDefaults.espSsid,
      ),
      espPassword: _preferStored(
        prefs.getString(_passwordKey),
        generatedDefaults.espPassword,
      ),
      baseUrl: _preferStored(
        prefs.getString(_baseUrlKey),
        generatedDefaults.baseUrl,
      ),
      hotspotBaseUrl: generatedDefaults.hotspotBaseUrl,
      sharedKey: _preferStored(sharedKey, generatedDefaults.sharedKey),
    );
  }

  Future<void> saveSettings(LocalUnlockSettings settings) async {
    await _persistSettings(settings);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_manualOverridesKey, true);
  }

  Future<LocalUnlockSettings> resetToDefaults() async {
    final LocalUnlockSettings defaults = LocalUnlockSettings(
      espSsid: LocalFallbackDefaults.espSsid,
      espPassword: LocalFallbackDefaults.espPassword,
      sharedKey: LocalFallbackDefaults.sharedKey,
      baseUrl: LocalFallbackDefaults.baseUrl,
      hotspotBaseUrl: LocalFallbackDefaults.hotspotBaseUrl,
    );

    await _persistSettings(defaults);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_manualOverridesKey, false);
    return defaults;
  }
}
