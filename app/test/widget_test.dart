import 'package:flutter_test/flutter_test.dart';
import 'package:poot/src/models/local_unlock_settings.dart';

void main() {
  test('local settings configuration check', () {
    const LocalUnlockSettings empty = LocalUnlockSettings(
      espSsid: '',
      espPassword: '',
      sharedSecret: '',
      baseUrl: 'http://192.168.4.1',
    );

    const LocalUnlockSettings ready = LocalUnlockSettings(
      espSsid: 'Poot-Lock',
      espPassword: 'password123',
      sharedSecret: 'supersecret',
      baseUrl: 'http://192.168.4.1',
    );

    expect(empty.isConfigured, isFalse);
    expect(ready.isConfigured, isTrue);
  });
}
