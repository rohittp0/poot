import 'package:flutter_test/flutter_test.dart';
import 'package:poot/src/models/local_unlock_settings.dart';

void main() {
  test('local settings isConfigured requires sharedKey and baseUrl', () {
    const LocalUnlockSettings empty = LocalUnlockSettings(
      homeWifiSsid: '',
      homeWifiPassword: '',
      sharedKey: '',
      baseUrl: 'http://192.168.1.192',
    );

    const LocalUnlockSettings ready = LocalUnlockSettings(
      homeWifiSsid: 'HomeWiFi',
      homeWifiPassword: 'password123',
      sharedKey: 'supersecret',
      baseUrl: 'http://192.168.1.192',
    );

    expect(empty.isConfigured, isFalse);
    expect(ready.isConfigured, isTrue);
  });
}
