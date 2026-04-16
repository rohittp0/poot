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
    homeWifiSsid: 'HomeWiFi',
    homeWifiPassword: 'password123',
    sharedKey: 'shared-key',
    baseUrl: 'http://192.168.1.192',
  );

  test('unlockViaLan sends correct request and returns success', () async {
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

    final LocalUnlockResult result = await service.unlockViaLan();

    expect(result.success, isTrue);
    expect(requests, <Uri>[
      Uri.parse('http://192.168.1.192/api/local-unlock?key=shared-key'),
    ]);
  });

  test('unlockViaLan returns invalid_key reason on 401', () async {
    final LocalUnlockService service = LocalUnlockService(
      settingsService: FakeSettingsService(settings),
      httpClient: MockClient(
        (_) async =>
            http.Response('{"ok":false,"code":"invalid_key"}', 401),
      ),
    );

    final LocalUnlockResult result = await service.unlockViaLan();

    expect(result.success, isFalse);
    expect(result.reason, 'invalid_key');
  });

  test('unlock calls LAN endpoint when lock is reachable via probe', () async {
    final List<Uri> requests = <Uri>[];
    final LocalUnlockService service = LocalUnlockService(
      settingsService: FakeSettingsService(settings),
      httpClient: MockClient((http.Request request) async {
        requests.add(request.url);
        if (request.url.path == '/') {
          return http.Response('Poot lock online', 200);
        }
        return http.Response('{"ok":true,"code":"ok"}', 200);
      }),
    );

    final LocalUnlockResult result = await service.unlock();

    expect(result.success, isTrue);
    expect(requests.last.path, '/api/local-unlock');
  });

  test('unlock proceeds to LAN endpoint even when probe fails', () async {
    final List<Uri> requests = <Uri>[];
    final LocalUnlockService service = LocalUnlockService(
      settingsService: FakeSettingsService(settings),
      httpClient: MockClient((http.Request request) async {
        requests.add(request.url);
        if (request.url.path == '/') {
          throw Exception('network unreachable');
        }
        return http.Response('{"ok":true,"code":"ok"}', 200);
      }),
    );

    final LocalUnlockResult result = await service.unlock();

    // WiFi connect attempt fails silently (no platform channels in tests),
    // then falls through to the unlock request which succeeds.
    expect(result.success, isTrue);
    expect(requests.last.path, '/api/local-unlock');
  });
}
