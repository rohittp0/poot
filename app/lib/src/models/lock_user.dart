class LockUser {
  const LockUser({
    required this.uid,
    required this.role,
    required this.enabled,
  });

  final String uid;
  final String role;
  final bool enabled;

  Map<String, Object?> toJson() {
    return {
      'role': role,
      'enabled': enabled,
      'updatedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
  }

  static LockUser fromJson(String uid, Map<Object?, Object?> json) {
    return LockUser(
      uid: uid,
      role: (json['role'] ?? 'member').toString(),
      enabled: json['enabled'] == true,
    );
  }
}
