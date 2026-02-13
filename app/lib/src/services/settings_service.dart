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
  static const String _secretKey = 'shared_hmac_secret';
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
      key: _secretKey,
      value: settings.sharedSecret.trim(),
    );
  }

  Future<LocalUnlockSettings> readSettings() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool hasManualOverrides = prefs.getBool(_manualOverridesKey) ?? false;

    final LocalUnlockSettings generatedDefaults = LocalUnlockSettings(
      espSsid: LocalFallbackDefaults.espSsid,
      espPassword: LocalFallbackDefaults.espPassword,
      sharedSecret: LocalFallbackDefaults.sharedSecret,
      baseUrl: LocalFallbackDefaults.baseUrl,
    );

    if (!hasManualOverrides) {
      await _persistSettings(generatedDefaults);
      return generatedDefaults;
    }

    final String? secret = await _secureStorage.read(key: _secretKey);

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
      sharedSecret: _preferStored(secret, generatedDefaults.sharedSecret),
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
      sharedSecret: LocalFallbackDefaults.sharedSecret,
      baseUrl: LocalFallbackDefaults.baseUrl,
    );

    await _persistSettings(defaults);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_manualOverridesKey, false);
    return defaults;
  }
}
