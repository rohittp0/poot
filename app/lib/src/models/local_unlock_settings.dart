class LocalUnlockSettings {
  const LocalUnlockSettings({
    required this.espSsid,
    required this.espPassword,
    required this.sharedSecret,
    required this.baseUrl,
  });

  final String espSsid;
  final String espPassword;
  final String sharedSecret;
  final String baseUrl;

  bool get isConfigured =>
      espSsid.isNotEmpty && espPassword.isNotEmpty && sharedSecret.isNotEmpty;

  LocalUnlockSettings copyWith({
    String? espSsid,
    String? espPassword,
    String? sharedSecret,
    String? baseUrl,
  }) {
    return LocalUnlockSettings(
      espSsid: espSsid ?? this.espSsid,
      espPassword: espPassword ?? this.espPassword,
      sharedSecret: sharedSecret ?? this.sharedSecret,
      baseUrl: baseUrl ?? this.baseUrl,
    );
  }
}
