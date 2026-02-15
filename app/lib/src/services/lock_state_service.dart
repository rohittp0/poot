import 'package:firebase_database/firebase_database.dart';

import '../config/app_config.dart';
import '../models/lock_state.dart';

class LockStateService {
  LockStateService({FirebaseDatabase? database})
    : _database = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _database;

  DatabaseReference get _stateRef =>
      _database.ref('locks/${AppConfig.lockId}/state');

  Stream<DeviceCloudState> watchState() {
    return _stateRef.onValue.map((DatabaseEvent event) {
      return DeviceCloudState.fromRaw(event.snapshot.value);
    });
  }

  Future<DeviceCloudState> fetchState() async {
    final DataSnapshot snapshot = await _stateRef.get();
    return DeviceCloudState.fromRaw(snapshot.value);
  }
}
