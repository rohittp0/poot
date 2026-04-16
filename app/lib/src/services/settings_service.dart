import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/local_fallback_defaults.dart';
import '../models/local_unlock_settings.dart';

class SettingsService {
  SettingsService({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secureStorage;

  static const String _homeWifiSsidKey = 'home_wifi_ssid';
  static const String _homeWifiPasswordKey = 'home_wifi_password';
  static const String _baseUrlKey = 'esp_base_url';
  static const String _sharedKeyStorageKey = 'shared_key';
  static const String _legacySharedSecretKey = 'shared_hmac_secret';
  static const String _manualOverridesKey = 'local_settings_manual_overrides';

  String _normalize(String? value) => value?.trim() ?? '';

  String _preferStored(String? stored, String fallback) {
    final String normalized = _normalize(stored);
    return normalized.isNotEmpty ? normalized : fallback;
  }

  Future<void> _persistSettings(LocalUnlockSettings settings) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_homeWifiSsidKey, settings.homeWifiSsid.trim());
    await prefs.setString(
      _homeWifiPasswordKey,
      settings.homeWifiPassword.trim(),
    );
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
      homeWifiSsid: LocalFallbackDefaults.homeWifiSsid,
      homeWifiPassword: LocalFallbackDefaults.homeWifiPassword,
      sharedKey: LocalFallbackDefaults.sharedKey,
      baseUrl: LocalFallbackDefaults.baseUrl,
    );

    if (!hasManualOverrides) {
      await _persistSettings(generatedDefaults);
      return generatedDefaults;
    }

    final String? sharedKey =
        await _secureStorage.read(key: _sharedKeyStorageKey) ??
        await _secureStorage.read(key: _legacySharedSecretKey);

    return LocalUnlockSettings(
      homeWifiSsid: _preferStored(
        prefs.getString(_homeWifiSsidKey),
        generatedDefaults.homeWifiSsid,
      ),
      homeWifiPassword: _preferStored(
        prefs.getString(_homeWifiPasswordKey),
        generatedDefaults.homeWifiPassword,
      ),
      baseUrl: _preferStored(
        prefs.getString(_baseUrlKey),
        generatedDefaults.baseUrl,
      ),
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
      homeWifiSsid: LocalFallbackDefaults.homeWifiSsid,
      homeWifiPassword: LocalFallbackDefaults.homeWifiPassword,
      sharedKey: LocalFallbackDefaults.sharedKey,
      baseUrl: LocalFallbackDefaults.baseUrl,
    );
    await _persistSettings(defaults);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_manualOverridesKey, false);
    return defaults;
  }
}
