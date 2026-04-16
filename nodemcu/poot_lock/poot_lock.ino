#include <Arduino.h>
#include <ArduinoJson.h>
#include <ESP8266WebServer.h>
#include <ESP8266WiFi.h>

#include "config.h"
#include "diagnostics.h"
#include "relay_control.h"
#include "secrets.h"

RelayController relay(poot::kRelayPin, poot::kRelayActiveLow);
ESP8266WebServer server(poot::kLocalHttpPort);

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

  // Unlock while connecting so the lock is never permanently inaccessible
  // if WiFi is down. The relay cooldown prevents double-firing on rapid retries.
  relay.triggerPulse(poot::kUnlockPulseMs, poot::kUnlockCooldownMs);

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

void setupWiFi() {
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.setSleepMode(WIFI_NONE_SLEEP);
  WiFi.mode(WIFI_STA);
  poot_diag::logf("WIFI", "mode STA");
  scanAndLogNetworks();
  connectSta();
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
}

void loop() {
  pumpLocalServer();
  relay.loop();
  logWiFiStatusIfChanged();
  ensureNetworkStack();
  pumpLocalServer();
  updateStatusLed();
  yield();
}
