import 'package:firebase_database/firebase_database.dart';

import '../config/app_config.dart';
import '../models/device_account.dart';
import '../models/lock_user.dart';

class AdminUsersService {
  AdminUsersService({FirebaseDatabase? database})
    : _database = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _database;

  DatabaseReference get _usersRef =>
      _database.ref('locks/${AppConfig.lockId}/users');
  DatabaseReference get _identityRef =>
      _database.ref('locks/${AppConfig.lockId}/identity');
  DatabaseReference get _deviceAccountRef =>
      _database.ref('locks/${AppConfig.lockId}/deviceAccount');

  String _normalizeEmail(String email) => email.trim().toLowerCase();
  int _nowEpochSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Stream<List<LockUser>> watchUsers() {
    return _usersRef.onValue.map((DatabaseEvent event) {
      final Object? raw = event.snapshot.value;
      if (raw is! Map<Object?, Object?>) {
        return const <LockUser>[];
      }

      final List<LockUser> users = <LockUser>[];
      for (final MapEntry<Object?, Object?> entry in raw.entries) {
        final String uid = entry.key.toString();
        final Object? value = entry.value;
        if (value is! Map<Object?, Object?>) {
          continue;
        }
        users.add(LockUser.fromJson(uid, value));
      }

      users.sort((LockUser a, LockUser b) => a.uid.compareTo(b.uid));
      return users;
    });
  }

  Stream<Map<String, String>> watchIdentityEmailsByUid() {
    return _identityRef.onValue.map((DatabaseEvent event) {
      final Object? raw = event.snapshot.value;
      if (raw is! Map<Object?, Object?>) {
        return const <String, String>{};
      }

      final Map<String, String> emailsByUid = <String, String>{};
      for (final MapEntry<Object?, Object?> entry in raw.entries) {
        final String uid = entry.key.toString();
        final Object? value = entry.value;
        if (value is! Map<Object?, Object?>) {
          continue;
        }

        final String email = (value['email'] ?? '').toString().trim();
        if (email.isEmpty) {
          continue;
        }
        emailsByUid[uid] = email;
      }

      return emailsByUid;
    });
  }

  Stream<DeviceAccount?> watchDeviceAccount() {
    return _deviceAccountRef.onValue.map((DatabaseEvent event) {
      return DeviceAccount.fromRaw(event.snapshot.value);
    });
  }

  Future<void> upsertIdentity({
    required String uid,
    required String? email,
  }) async {
    final String normalized = _normalizeEmail(email ?? '');
    if (normalized.isEmpty) {
      return;
    }

    await _identityRef.child(uid).set(<String, Object?>{
      'email': normalized,
      'updatedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  Future<LockUser?> getUser(String uid) async {
    try {
      final DataSnapshot snapshot = await _usersRef.child(uid).get();
      final Object? raw = snapshot.value;
      if (raw is! Map<Object?, Object?>) {
        return null;
      }

      return LockUser.fromJson(uid, raw);
    } catch (_) {
      return null;
    }
  }

  String? _firstUidForEmailValue(Object? raw, String normalizedEmail) {
    if (raw is! Map<Object?, Object?>) {
      return null;
    }

    for (final MapEntry<Object?, Object?> entry in raw.entries) {
      final Object? value = entry.value;
      if (value is! Map<Object?, Object?>) {
        continue;
      }

      final String email = _normalizeEmail((value['email'] ?? '').toString());
      if (email == normalizedEmail) {
        return entry.key.toString();
      }
    }

    return null;
  }

  Future<String?> findUidByEmail(String email) async {
    final String normalizedEmail = _normalizeEmail(email);
    if (normalizedEmail.isEmpty) {
      return null;
    }

    final DataSnapshot exactSnapshot =
        await _identityRef.orderByChild('email').equalTo(normalizedEmail).get();
    final String? exactUid = _firstUidForEmailValue(
      exactSnapshot.value,
      normalizedEmail,
    );
    if (exactUid != null) {
      return exactUid;
    }

    final DataSnapshot fullSnapshot = await _identityRef.get();
    return _firstUidForEmailValue(fullSnapshot.value, normalizedEmail);
  }

  Future<void> setDeviceAccountByEmail(String email) async {
    final String normalizedEmail = _normalizeEmail(email);
    if (normalizedEmail.isEmpty) {
      throw ArgumentError('Email is required.');
    }

    final String? uid = await findUidByEmail(normalizedEmail);
    if (uid == null) {
      throw StateError('User must sign in once before being assigned.');
    }

    await _deviceAccountRef.set(<String, Object?>{
      'uid': uid,
      'email': normalizedEmail,
      'enabled': true,
      'updatedAt': _nowEpochSec(),
    });
  }

  Future<void> setDeviceAccountEnabled(bool enabled) async {
    final DataSnapshot snapshot = await _deviceAccountRef.get();
    final DeviceAccount? current = DeviceAccount.fromRaw(snapshot.value);
    if (current == null) {
      throw StateError('Device account is not configured.');
    }

    await _deviceAccountRef.update(<String, Object?>{
      'enabled': enabled,
      'updatedAt': _nowEpochSec(),
    });
  }

  Future<void> setEnabled(String uid, bool enabled) {
    return _usersRef.child(uid).update(<String, Object?>{
      'enabled': enabled,
      'updatedAt': _nowEpochSec(),
    });
  }

  Future<void> setRole(String uid, String role) {
    return _usersRef.child(uid).update(<String, Object?>{
      'role': role,
      'updatedAt': _nowEpochSec(),
    });
  }

  Future<void> upsertUser({
    required String uid,
    required String role,
    required bool enabled,
  }) {
    final LockUser user = LockUser(uid: uid, role: role, enabled: enabled);
    return _usersRef.child(uid).set(user.toJson());
  }
}
