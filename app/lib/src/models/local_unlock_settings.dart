class LocalUnlockSettings {
  const LocalUnlockSettings({
    required this.homeWifiSsid,
    required this.homeWifiPassword,
    required this.sharedKey,
    required this.baseUrl,
  });

  final String homeWifiSsid;
  final String homeWifiPassword;
  final String sharedKey;
  final String baseUrl;

  bool get isConfigured => sharedKey.isNotEmpty && baseUrl.isNotEmpty;

  LocalUnlockSettings copyWith({
    String? homeWifiSsid,
    String? homeWifiPassword,
    String? sharedKey,
    String? baseUrl,
  }) {
    return LocalUnlockSettings(
      homeWifiSsid: homeWifiSsid ?? this.homeWifiSsid,
      homeWifiPassword: homeWifiPassword ?? this.homeWifiPassword,
      sharedKey: sharedKey ?? this.sharedKey,
      baseUrl: baseUrl ?? this.baseUrl,
    );
  }
}
