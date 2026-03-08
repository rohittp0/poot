class LocalUnlockSettings {
  const LocalUnlockSettings({
    required this.espSsid,
    required this.espPassword,
    required this.sharedKey,
    required this.baseUrl,
    required this.hotspotBaseUrl,
  });

  final String espSsid;
  final String espPassword;
  final String sharedKey;
  final String baseUrl;
  final String hotspotBaseUrl;

  bool get isConfigured =>
      espSsid.isNotEmpty &&
      espPassword.isNotEmpty &&
      sharedKey.isNotEmpty &&
      baseUrl.isNotEmpty &&
      hotspotBaseUrl.isNotEmpty;

  LocalUnlockSettings copyWith({
    String? espSsid,
    String? espPassword,
    String? sharedKey,
    String? baseUrl,
    String? hotspotBaseUrl,
  }) {
    return LocalUnlockSettings(
      espSsid: espSsid ?? this.espSsid,
      espPassword: espPassword ?? this.espPassword,
      sharedKey: sharedKey ?? this.sharedKey,
      baseUrl: baseUrl ?? this.baseUrl,
      hotspotBaseUrl: hotspotBaseUrl ?? this.hotspotBaseUrl,
    );
  }
}
