class DeviceAccount {
  const DeviceAccount({
    required this.uid,
    required this.email,
    required this.enabled,
    required this.updatedAt,
  });

  final String uid;
  final String email;
  final bool enabled;
  final int updatedAt;

  static DeviceAccount? fromRaw(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      return null;
    }

    final String uid = (raw['uid'] ?? '').toString().trim();
    final String email = (raw['email'] ?? '').toString().trim().toLowerCase();
    final bool enabled = raw['enabled'] == true;
    final int updatedAt =
        (raw['updatedAt'] is num) ? (raw['updatedAt'] as num).toInt() : 0;

    if (uid.isEmpty || email.isEmpty) {
      return null;
    }

    return DeviceAccount(
      uid: uid,
      email: email,
      enabled: enabled,
      updatedAt: updatedAt,
    );
  }
}
