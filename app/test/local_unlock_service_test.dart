import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:poot/src/models/local_unlock_settings.dart';
import 'package:poot/src/services/local_unlock_service.dart';
import 'package:poot/src/services/settings_service.dart';

class FakeSettingsService extends SettingsService {
  FakeSettingsService(this._settings);

  final LocalUnlockSettings _settings;

  @override
  Future<LocalUnlockSettings> readSettings() async => _settings;
}

void main() {
  const LocalUnlockSettings settings = LocalUnlockSettings(
    espSsid: 'Poot',
    espPassword: 'password123',
    sharedKey: 'shared-key',
    baseUrl: 'http://192.168.1.192',
    hotspotBaseUrl: 'http://192.168.4.1',
  );

  test('uses LAN first when the fixed IP responds', () async {
    final List<Uri> requests = <Uri>[];
    final LocalUnlockService service = LocalUnlockService(
      settingsService: FakeSettingsService(settings),
      httpClient: MockClient((http.Request request) async {
        requests.add(request.url);
        expect(request.method, 'GET');
        expect(request.url.queryParameters, <String, String>{
          'key': settings.sharedKey,
        });
        return http.Response('{"ok":true,"code":"ok"}', 200);
      }),
    );

    final LocalUnlockResult result = await service.unlockLocally();

    expect(result.success, isTrue);
    expect(requests, <Uri>[
      Uri.parse('http://192.168.1.192/api/local-unlock?key=shared-key'),
    ]);
  });

  test('falls back to hotspot after LAN transport failure', () async {
    final List<Uri> requests = <Uri>[];
    final LocalUnlockService service = LocalUnlockService(
      settingsService: FakeSettingsService(settings),
      httpClient: MockClient((http.Request request) async {
        requests.add(request.url);
        if (request.url.host == '192.168.1.192') {
          throw Exception('network unreachable');
        }
        return http.Response('{"ok":true,"code":"ok"}', 200);
      }),
    );

    final LocalUnlockResult result = await service.unlockLocally();

    expect(result.success, isTrue);
    expect(requests, <Uri>[
      Uri.parse('http://192.168.1.192/api/local-unlock?key=shared-key'),
      Uri.parse('http://192.168.4.1/api/local-unlock?key=shared-key'),
    ]);
  });

  test('does not fall back when LAN returns an auth failure', () async {
    final List<Uri> requests = <Uri>[];
    final LocalUnlockService service = LocalUnlockService(
      settingsService: FakeSettingsService(settings),
      httpClient: MockClient((http.Request request) async {
        requests.add(request.url);
        return http.Response('{"ok":false,"code":"invalid_key"}', 401);
      }),
    );

    final LocalUnlockResult result = await service.unlockLocally();

    expect(result.success, isFalse);
    expect(result.reason, 'invalid_key');
    expect(requests, <Uri>[
      Uri.parse('http://192.168.1.192/api/local-unlock?key=shared-key'),
    ]);
  });
}
