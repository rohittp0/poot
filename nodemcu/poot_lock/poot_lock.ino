#include <Arduino.h>
#include <ArduinoJson.h>
#include <ArduinoOTA.h>
#include <ESP8266WebServer.h>
#include <ESP8266WiFi.h>
#include <ESP8266mDNS.h>

#include "config.h"
#include "diagnostics.h"
#include "relay_control.h"
#include "secrets.h"

RelayController relay(poot::kRelayPin, poot::kRelayActiveLow);
ESP8266WebServer server(poot::kLocalHttpPort);

WiFiEventHandler gOnStaDisconnected;
WiFiEventHandler gOnStaGotIp;
volatile bool gReassertHttpRequested = false;

const IPAddress kStaIp = WIFI_STA_IP;
const IPAddress kStaGateway = WIFI_STA_GATEWAY;
const IPAddress kStaSubnet = WIFI_STA_SUBNET;
const IPAddress kStaDns1 = WIFI_STA_DNS1;
const IPAddress kStaDns2 = WIFI_STA_DNS2;

uint32_t lastWiFiReconnectMs = 0;
uint32_t lastNetworkEnsureMs = 0;
uint32_t lastWiFiBeginMs = 0;
bool serverRoutesRegistered = false;
bool serverStarted = false;

wl_status_t lastWiFiStatus = WL_IDLE_STATUS;
uint32_t lastWiFiStatusLogMs = 0;

enum class LedMode {
  kOff,
  kOn,
  kBlinkSlow,
  kBlinkFast,
};

LedMode ledMode = LedMode::kOff;
bool ledIsLit = false;
uint32_t ledLastToggleMs = 0;

const char* ledModeName(LedMode mode) {
  switch (mode) {
    case LedMode::kOff:      return "off";
    case LedMode::kOn:       return "on";
    case LedMode::kBlinkSlow: return "blink_slow";
    case LedMode::kBlinkFast: return "blink_fast";
    default:                 return "unknown";
  }
}

const char* wifiStatusName(wl_status_t status) {
  switch (status) {
    case WL_CONNECTED:       return "connected";
    case WL_NO_SSID_AVAIL:   return "no_ssid";
    case WL_CONNECT_FAILED:  return "connect_failed";
    case WL_CONNECTION_LOST: return "connection_lost";
    case WL_WRONG_PASSWORD:  return "wrong_password";
    case WL_DISCONNECTED:    return "disconnected";
    case WL_IDLE_STATUS:     return "idle";
    default:                 return "unknown";
  }
}

const char* encTypeName(uint8_t enc) {
  switch (enc) {
    case ENC_TYPE_NONE: return "open";
    case ENC_TYPE_WEP:  return "wep";
    case ENC_TYPE_TKIP: return "wpa";
    case ENC_TYPE_CCMP: return "wpa2";
    case ENC_TYPE_AUTO: return "auto";
    default:            return "unknown";
  }
}

void scanAndLogNetworks() {
  poot_diag::logf("WIFI", "scanning for networks...");
  const int count = WiFi.scanNetworks();
  if (count <= 0) {
    poot_diag::logf("WIFI", "scan found 0 networks (count=%d)", count);
    return;
  }
  poot_diag::logf("WIFI", "scan found %d networks:", count);
  for (int i = 0; i < count; i++) {
    poot_diag::logf("WIFI", "  [%d] ssid=\"%s\" rssi=%d ch=%d enc=%s",
                    i, WiFi.SSID(i).c_str(), WiFi.RSSI(i),
                    WiFi.channel(i), encTypeName(WiFi.encryptionType(i)));
  }
  WiFi.scanDelete();
}

void logWiFiStatusIfChanged() {
  const wl_status_t status = WiFi.status();
  const uint32_t nowMs = millis();
  if (status == lastWiFiStatus &&
      nowMs - lastWiFiStatusLogMs < poot::kWiFiStatusLogIntervalMs) {
    return;
  }

  lastWiFiStatus = status;
  lastWiFiStatusLogMs = nowMs;

  if (status == WL_CONNECTED) {
    poot_diag::logf("WIFI", "STA connected ip=%s rssi=%d ssid=%s",
                    WiFi.localIP().toString().c_str(), WiFi.RSSI(),
                    WiFi.SSID().c_str());
    return;
  }

  poot_diag::logf("WIFI", "STA status=%s (%d)", wifiStatusName(status), status);
}

void pumpLocalServer() {
  server.handleClient();
  yield();
}

void writeStatusLed(bool on) {
  ledIsLit = on;
  const uint8_t level = poot::kStatusLedActiveLow ? (on ? LOW : HIGH)
                                                   : (on ? HIGH : LOW);
  digitalWrite(poot::kStatusLedPin, level);
}

void setupStatusLed() {
  pinMode(poot::kStatusLedPin, OUTPUT);
  writeStatusLed(false);
  poot_diag::logf("LED", "status LED initialized pin=%u activeLow=%u",
                  poot::kStatusLedPin, poot::kStatusLedActiveLow ? 1 : 0);
}

bool isWiFiConnecting() {
  if (WiFi.status() == WL_CONNECTED) {
    return false;
  }
  if (WiFi.status() == WL_IDLE_STATUS) {
    return true;
  }
  return millis() - lastWiFiBeginMs <= poot::kWiFiConnectingWindowMs;
}

LedMode desiredLedMode() {
  if (relay.isRelayOn()) {
    return LedMode::kOff;
  }
  if (WiFi.status() == WL_CONNECTED) {
    return LedMode::kOn;
  }
  if (isWiFiConnecting()) {
    return LedMode::kBlinkFast;
  }
  return LedMode::kBlinkSlow;
}

void updateStatusLed() {
  const LedMode target = desiredLedMode();
  const uint32_t nowMs = millis();

  if (target != ledMode) {
    ledMode = target;
    ledLastToggleMs = nowMs;
    poot_diag::logf("LED", "mode=%s", ledModeName(ledMode));
    if (ledMode == LedMode::kBlinkFast || ledMode == LedMode::kBlinkSlow) {
      writeStatusLed(true);
    }
  }

  switch (ledMode) {
    case LedMode::kOff:
      if (ledIsLit) {
        writeStatusLed(false);
      }
      break;
    case LedMode::kOn:
      if (!ledIsLit) {
        writeStatusLed(true);
      }
      break;
    case LedMode::kBlinkFast:
    case LedMode::kBlinkSlow: {
      const uint32_t intervalMs =
          (ledMode == LedMode::kBlinkFast) ? poot::kStatusBlinkFastMs
                                           : poot::kStatusBlinkSlowMs;
      if (nowMs - ledLastToggleMs >= intervalMs) {
        ledLastToggleMs = nowMs;
        writeStatusLed(!ledIsLit);
      }
      break;
    }
  }
}

bool configureStaNetwork() {
  const bool configured =
      WiFi.config(kStaIp, kStaGateway, kStaSubnet, kStaDns1, kStaDns2);
  poot_diag::logf(
      "WIFI",
      "STA static ip config=%s ip=%s gateway=%s subnet=%s dns1=%s dns2=%s",
      configured ? "ok" : "failed", kStaIp.toString().c_str(),
      kStaGateway.toString().c_str(), kStaSubnet.toString().c_str(),
      kStaDns1.toString().c_str(), kStaDns2.toString().c_str());
  return configured;
}

void connectSta(bool forceReconnect = false) {
  if (!forceReconnect && WiFi.status() == WL_CONNECTED) {
    return;
  }

  const wl_status_t prevStatus = WiFi.status();
  poot_diag::logf("WIFI", "connectSta force=%u prevStatus=%s(%d)",
                  forceReconnect ? 1 : 0, wifiStatusName(prevStatus), prevStatus);

  if (forceReconnect) {
    WiFi.disconnect(false);
    yield();
  }

  configureStaNetwork();
  lastWiFiBeginMs = millis();
  lastWiFiReconnectMs = lastWiFiBeginMs;
  poot_diag::logf("WIFI", "STA connecting to ssid=%s pwdLen=%u",
                  WIFI_STA_SSID, (unsigned)strlen(WIFI_STA_PASSWORD));
  WiFi.begin(WIFI_STA_SSID, WIFI_STA_PASSWORD);
}

template <typename TDoc>
void sendJson(int code, const TDoc& doc) {
  String body;
  serializeJson(doc, body);
  server.send(code, "application/json", body);
}

void ensureHttpServer(bool forceRestart = false) {
  if (!serverRoutesRegistered) {
    server.on("/", HTTP_GET, []() {
      poot_diag::logf("HTTP", "GET /");
      server.send(200, "text/plain", "Poot lock online");
    });

    server.on("/api/local-unlock", HTTP_GET, []() {
      StaticJsonDocument<256> response;
      const String remoteIp = server.client().remoteIP().toString();
      poot_diag::logf("LOCAL_HTTP", "GET /api/local-unlock from %s",
                      remoteIp.c_str());

      if (!server.hasArg("key")) {
        poot_diag::logf("LOCAL_HTTP", "bad_request: missing key");
        response["ok"] = false;
        response["code"] = "bad_request";
        response["message"] = "Missing key query parameter";
        sendJson(400, response);
        return;
      }

      const String key = server.arg("key");
      if (key.isEmpty() || key != LOCAL_SHARED_KEY) {
        poot_diag::logf("LOCAL_HTTP", "unlock denied reason=invalid_key");
        response["ok"] = false;
        response["code"] = "invalid_key";
        response["message"] = "Local unlock denied";
        sendJson(401, response);
        return;
      }

      const bool fired =
          relay.triggerPulse(poot::kUnlockPulseMs, poot::kUnlockCooldownMs);
      const String reason = fired ? "ok" : "cooldown";
      poot_diag::logf("LOCAL_HTTP", "unlock %s",
                      fired ? "success" : "denied_cooldown");

      response["ok"] = fired;
      response["code"] = reason;
      response["message"] = fired ? "Unlocked" : "Relay cooldown active";
      sendJson(fired ? 200 : 429, response);
    });

    server.on("/api/health", HTTP_GET, []() {
      const String remoteIp = server.client().remoteIP().toString();
      poot_diag::logf("LOCAL_HTTP", "GET /api/health from %s", remoteIp.c_str());

      if (!server.hasArg("key") || server.arg("key") != LOCAL_SHARED_KEY) {
        StaticJsonDocument<128> denied;
        denied["ok"] = false;
        denied["code"] = "invalid_key";
        denied["message"] = "Health denied";
        sendJson(401, denied);
        return;
      }

      StaticJsonDocument<384> health;
      health["ok"] = true;
      health["version"] = poot::kFirmwareVersion;
      health["uptime_ms"] = millis();
      health["free_heap"] = ESP.getFreeHeap();
      health["reset_reason"] = ESP.getResetReason();
      JsonObject sta = health.createNestedObject("sta");
      sta["status"] = wifiStatusName(WiFi.status());
      sta["ip"] = WiFi.localIP().toString();
      sta["rssi"] = WiFi.RSSI();
      sta["ssid"] = WiFi.SSID();
      JsonObject ap = health.createNestedObject("ap");
      ap["ip"] = WiFi.softAPIP().toString();
      ap["stations"] = WiFi.softAPgetStationNum();
      JsonObject rly = health.createNestedObject("relay");
      rly["on"] = relay.isRelayOn();
      rly["cooling"] = relay.isCoolingDown();
      sendJson(200, health);
    });

    server.onNotFound([]() {
      poot_diag::logf("HTTP", "404 %s", server.uri().c_str());
      StaticJsonDocument<128> response;
      response["ok"] = false;
      response["code"] = "not_found";
      response["message"] = "Route not found";
      sendJson(404, response);
    });

    serverRoutesRegistered = true;
  }

  if (!serverStarted || forceRestart) {
    const bool wasStarted = serverStarted;
    if (serverStarted) {
      server.stop();
      yield();
    }
    server.begin();
    serverStarted = true;
    poot_diag::logf("HTTP", "server %s on port=%u",
                    wasStarted ? "ensured" : "started",
                    poot::kLocalHttpPort);
  }
}

void setupSoftAp() {
  const IPAddress apIp(192, 168, 4, 1);
  const IPAddress apGateway(192, 168, 4, 1);
  const IPAddress apSubnet(255, 255, 255, 0);
  const bool configured = WiFi.softAPConfig(apIp, apGateway, apSubnet);
  const bool apOk = WiFi.softAP(WIFI_AP_SSID, WIFI_AP_PASSWORD,
                                WIFI_AP_CHANNEL, /*hidden=*/false,
                                poot::kApMaxConnections);
  poot_diag::logf("AP",
                  "softAP config=%s up=%s ssid=%s ip=%s channel=%u maxConn=%u",
                  configured ? "ok" : "failed", apOk ? "ok" : "failed",
                  WIFI_AP_SSID, WiFi.softAPIP().toString().c_str(),
                  (unsigned)WIFI_AP_CHANNEL, (unsigned)poot::kApMaxConnections);
}

void registerWiFiEventHandlers() {
  gOnStaDisconnected =
      WiFi.onStationModeDisconnected([](const WiFiEventStationModeDisconnected& e) {
        poot_diag::logf("WIFI", "STA disconnected ssid=%s reason=%u",
                        e.ssid.c_str(), e.reason);
      });
  gOnStaGotIp = WiFi.onStationModeGotIP([](const WiFiEventStationModeGotIP& e) {
    poot_diag::logf("WIFI", "STA got ip=%s mask=%s gw=%s",
                    e.ip.toString().c_str(), e.mask.toString().c_str(),
                    e.gw.toString().c_str());
    // Defer server.stop()/begin() and mDNS work to loop() — running them
    // inside the SDK event context can race the active server.
    gReassertHttpRequested = true;
  });
}

void setupWiFi() {
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.setSleepMode(WIFI_NONE_SLEEP);
  WiFi.mode(WIFI_AP_STA);
  WiFi.setHostname(poot::kMdnsHostname);
  poot_diag::logf("WIFI", "mode AP_STA hostname=%s", poot::kMdnsHostname);
  setupSoftAp();
  registerWiFiEventHandlers();
  scanAndLogNetworks();
  connectSta();
}

void setupMdns() {
  if (MDNS.begin(poot::kMdnsHostname)) {
    MDNS.addService("http", "tcp", poot::kLocalHttpPort);
    poot_diag::logf("MDNS", "responder up as %s.local", poot::kMdnsHostname);
  } else {
    poot_diag::logf("MDNS", "begin failed");
  }
}

void setupOta() {
  ArduinoOTA.setHostname(poot::kMdnsHostname);
  ArduinoOTA.setPort(poot::kOtaPort);
  ArduinoOTA.setPassword(OTA_PASSWORD);
  ArduinoOTA.onStart([]() {
    const char* type = (ArduinoOTA.getCommand() == U_FLASH) ? "flash" : "fs";
    poot_diag::logf("OTA", "update start type=%s", type);
  });
  ArduinoOTA.onEnd([]() { poot_diag::logf("OTA", "update end"); });
  ArduinoOTA.onProgress([](unsigned int progress, unsigned int total) {
    static unsigned int lastPct = 0;
    const unsigned int pct = (total == 0) ? 0 : (progress * 100u) / total;
    if (pct != lastPct && pct % 10u == 0) {
      poot_diag::logf("OTA", "progress %u%%", pct);
      lastPct = pct;
    }
  });
  ArduinoOTA.onError([](ota_error_t e) { poot_diag::logf("OTA", "error %u", e); });
  ArduinoOTA.begin();
  poot_diag::logf("OTA", "ready hostname=%s port=%u", poot::kMdnsHostname,
                  (unsigned)poot::kOtaPort);
}

void maybeAutoReboot() {
  if (millis() < poot::kAutoRebootIntervalMs) {
    return;
  }
  poot_diag::logf("WDT", "auto-reboot: %lu ms uptime, scheduled hourly reset",
                  millis());
  Serial.flush();
  delay(50);
  ESP.restart();
}

void ensureNetworkStack() {
  const uint32_t nowMs = millis();
  if (nowMs - lastNetworkEnsureMs < poot::kNetworkEnsureMs) {
    return;
  }
  lastNetworkEnsureMs = nowMs;

  ensureHttpServer();

  if (WiFi.status() == WL_CONNECTED) {
    if (WiFi.localIP() != kStaIp) {
      poot_diag::logf("WIFI", "STA ip mismatch expected=%s actual=%s",
                      kStaIp.toString().c_str(),
                      WiFi.localIP().toString().c_str());
      connectSta(true);
    }
    return;
  }

  if (nowMs - lastWiFiReconnectMs < poot::kWiFiReconnectMs) {
    return;
  }

  poot_diag::logf("WIFI", "reconnect attempt");
  connectSta(true);
}

void setup() {
  Serial.begin(poot::kSerialBaud);
  relay.begin();
  delay(150);
  poot_diag::logf("BOOT", "Poot firmware booting version=%s",
                  poot::kFirmwareVersion);
  poot_diag::logf("BOOT", "reset reason=%s", ESP.getResetReason().c_str());
  poot_diag::logf("BOOT", "build timestamp=%s %s", __DATE__, __TIME__);
  randomSeed(analogRead(A0));

  setupStatusLed();
  poot_diag::logf("BOOT", "local auth=shared_key ip=%s",
                  kStaIp.toString().c_str());

  setupWiFi();
  ensureHttpServer();
  setupMdns();
  setupOta();
}

void loop() {
  pumpLocalServer();
  if (gReassertHttpRequested) {
    gReassertHttpRequested = false;
    poot_diag::logf("HTTP", "re-asserting after STA got IP");
    ensureHttpServer(/*forceRestart=*/true);
    MDNS.notifyAPChange();
  }
  relay.loop();
  logWiFiStatusIfChanged();
  ensureNetworkStack();
  pumpLocalServer();
  ArduinoOTA.handle();
  MDNS.update();
  maybeAutoReboot();
  updateStatusLed();
  yield();
}
