class DeviceCloudState {
  const DeviceCloudState({
    required this.online,
    required this.wifiConnected,
    required this.relayState,
    required this.lastSeenEpochSec,
    required this.fwVersion,
  });

  factory DeviceCloudState.fromRaw(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      return const DeviceCloudState(
        online: false,
        wifiConnected: false,
        relayState: 'unknown',
        lastSeenEpochSec: null,
        fwVersion: '',
      );
    }

    return DeviceCloudState(
      online: raw['online'] == true,
      wifiConnected: raw['wifiConnected'] == true,
      relayState: (raw['relayState'] ?? 'unknown').toString(),
      lastSeenEpochSec: _asInt(raw['lastSeen']),
      fwVersion: (raw['fwVersion'] ?? '').toString(),
    );
  }

  final bool online;
  final bool wifiConnected;
  final String relayState;
  final int? lastSeenEpochSec;
  final String fwVersion;
}

int? _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}
