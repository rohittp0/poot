#include <Arduino.h>
#include <ArduinoJson.h>
#include <ESP8266WebServer.h>
#include <ESP8266WiFi.h>

#include "config.h"
#include "diagnostics.h"
#include "firebase_client.h"
#include "relay_control.h"
#include "secrets.h"

RelayController relay(poot::kRelayPin, poot::kRelayActiveLow);
FirebaseClient firebase;
ESP8266WebServer server(poot::kLocalHttpPort);

const IPAddress kStaIp = WIFI_STA_IP;
const IPAddress kStaGateway = WIFI_STA_GATEWAY;
const IPAddress kStaSubnet = WIFI_STA_SUBNET;
const IPAddress kStaDns1 = WIFI_STA_DNS1;
const IPAddress kStaDns2 = WIFI_STA_DNS2;
const IPAddress kApIp(192, 168, 4, 1);
const IPAddress kApGateway(192, 168, 4, 1);
const IPAddress kApSubnet(255, 255, 255, 0);

String processedCommandIds[16];
size_t processedCount = 0;

uint32_t lastCloudPollMs = 0;
uint32_t lastHeartbeatMs = 0;
uint32_t lastWiFiReconnectMs = 0;
uint32_t lastNetworkEnsureMs = 0;
uint32_t lastWiFiBeginMs = 0;
uint32_t lastApStartMs = 0;
uint32_t lastHttpServerStartMs = 0;
uint32_t lastLocalHttpActivityMs = 0;
uint32_t lastLocalPriorityLogMs = 0;
uint32_t wifiConnectedSinceMs = 0;
uint32_t lastCloudHoldoffLogMs = 0;
uint32_t cloudStartDelayMs = poot::kCloudStartDelayAfterWiFiMs;
uint32_t lastCloudPollFailureLogMs = 0;
String lastCloudPollFailureReason;
uint32_t lastHeartbeatSkipLogMs = 0;
String lastHeartbeatSkipReason;
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
    case LedMode::kOff:
      return "off";
    case LedMode::kOn:
      return "on";
    case LedMode::kBlinkSlow:
      return "blink_slow";
    case LedMode::kBlinkFast:
      return "blink_fast";
    default:
      return "unknown";
  }
}

const char* wifiStatusName(wl_status_t status) {
  switch (status) {
    case WL_CONNECTED:
      return "connected";
    case WL_NO_SSID_AVAIL:
      return "no_ssid";
    case WL_CONNECT_FAILED:
      return "connect_failed";
    case WL_CONNECTION_LOST:
      return "connection_lost";
    case WL_DISCONNECTED:
      return "disconnected";
    case WL_IDLE_STATUS:
      return "idle";
    default:
      return "unknown";
  }
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
    if (wifiConnectedSinceMs == 0) {
      wifiConnectedSinceMs = nowMs;
    }
    poot_diag::logf("WIFI", "STA connected ip=%s rssi=%d ssid=%s",
                    WiFi.localIP().toString().c_str(), WiFi.RSSI(),
                    WiFi.SSID().c_str());
    return;
  }

  wifiConnectedSinceMs = 0;
  poot_diag::logf("WIFI", "STA status=%s (%d)", wifiStatusName(status), status);
}

bool isCloudReady() {
  if (WiFi.status() != WL_CONNECTED) {
    return false;
  }
  if (wifiConnectedSinceMs == 0) {
    return false;
  }
  return millis() - wifiConnectedSinceMs >= cloudStartDelayMs;
}

void logCloudHoldoff(const char* scope) {
  const uint32_t nowMs = millis();
  if (nowMs - lastCloudHoldoffLogMs < 4000) {
    return;
  }
  lastCloudHoldoffLogMs = nowMs;

  if (WiFi.status() != WL_CONNECTED) {
    poot_diag::logf(scope, "cloud holdoff: wifi not connected");
    return;
  }
  const uint32_t elapsed = (wifiConnectedSinceMs == 0) ? 0 : (nowMs - wifiConnectedSinceMs);
  poot_diag::logf(scope, "cloud holdoff: waiting %lu/%lu ms after wifi connect",
                  elapsed, cloudStartDelayMs);
}

void markLocalHttpActivity() { lastLocalHttpActivityMs = millis(); }

uint8_t softApClientCount() {
  return static_cast<uint8_t>(WiFi.softAPgetStationNum());
}

bool hasRecentLocalHttpActivity() {
  return lastLocalHttpActivityMs != 0 &&
         millis() - lastLocalHttpActivityMs <= poot::kLocalPriorityHoldMs;
}

bool localPriorityActive() {
  return softApClientCount() > 0 || hasRecentLocalHttpActivity();
}

void logLocalPriorityHoldoff(const char* scope) {
  const uint32_t nowMs = millis();
  if (nowMs - lastLocalPriorityLogMs < 4000) {
    return;
  }
  lastLocalPriorityLogMs = nowMs;

  poot_diag::logf(scope, "local priority active apClients=%u recentHttp=%u",
                  softApClientCount(), hasRecentLocalHttpActivity() ? 1 : 0);
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
    // During unlock pulse keep LED off.
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

bool hasProcessedCommand(const String& commandId) {
  for (size_t i = 0; i < processedCount; i++) {
    if (processedCommandIds[i].equals(commandId)) {
      return true;
    }
  }
  return false;
}

void rememberProcessedCommand(const String& commandId) {
  if (processedCount < 16) {
    processedCommandIds[processedCount++] = commandId;
    return;
  }

  for (size_t i = 1; i < 16; i++) {
    processedCommandIds[i - 1] = processedCommandIds[i];
  }
  processedCommandIds[15] = commandId;
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

  if (forceReconnect) {
    WiFi.disconnect(false);
    yield();
  }

  configureStaNetwork();
  lastWiFiBeginMs = millis();
  lastWiFiReconnectMs = lastWiFiBeginMs;
  poot_diag::logf("WIFI", "STA connecting to ssid=%s", WIFI_STA_SSID);
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
      markLocalHttpActivity();
      poot_diag::logf("HTTP", "GET /");
      server.send(200, "text/plain", "Poot lock online");
    });

    server.on("/api/local-unlock", HTTP_GET, []() {
      markLocalHttpActivity();
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
      poot_diag::logf("LOCAL_HTTP", "request keyLen=%u", key.length());

      if (key.isEmpty() || key != LOCAL_SHARED_KEY) {
        poot_diag::logf("LOCAL_HTTP", "unlock denied reason=invalid_key");
        firebase.writeAudit("unlock", "local", "denied", "invalid_key", "",
                            "");
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
      firebase.writeAudit("unlock", "local", fired ? "success" : "denied",
                          reason, "", "");

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

  const uint32_t nowMs = millis();
  const bool periodicRestart =
      serverStarted &&
      (nowMs - lastHttpServerStartMs >= poot::kHttpServerReassertMs) &&
      !localPriorityActive();
  if (!serverStarted || forceRestart || periodicRestart) {
    const bool wasStarted = serverStarted;
    if (serverStarted) {
      server.stop();
      yield();
    }
    server.begin();
    serverStarted = true;
    lastHttpServerStartMs = nowMs;
    poot_diag::logf("HTTP", "server %s on port=%u",
                    wasStarted ? "ensured" : "started",
                    poot::kLocalHttpPort);
  }
}

bool ensureAccessPoint(bool forceRestart = false) {
  const uint32_t nowMs = millis();
  bool shouldRestart = forceRestart;
  const bool periodicRestart =
      lastApStartMs != 0 && (nowMs - lastApStartMs >= poot::kApReassertMs) &&
      !localPriorityActive();

  if (WiFi.getMode() != WIFI_AP_STA) {
    WiFi.mode(WIFI_AP_STA);
    shouldRestart = true;
    poot_diag::logf("WIFI", "mode restored to AP+STA");
  }

  if (WiFi.softAPIP() != kApIp) {
    shouldRestart = true;
  }

  if (lastApStartMs == 0) {
    shouldRestart = true;
  }

  if (periodicRestart) {
    shouldRestart = true;
  }

  if (!shouldRestart) {
    return false;
  }

  if (lastApStartMs != 0) {
    WiFi.softAPdisconnect(false);
    yield();
  }

  const bool apConfigured = WiFi.softAPConfig(kApIp, kApGateway, kApSubnet);
  const bool apStarted =
      WiFi.softAP(AP_SSID, AP_PASSWORD, poot::kApChannel, false,
                  poot::kApMaxConnections);
  if (apStarted) {
    lastApStartMs = nowMs;
  } else {
    lastApStartMs = 0;
  }
  poot_diag::logf("WIFI",
                  "AP %s config=%s ssid=%s ip=%s channel=%u maxClients=%u",
                  apStarted ? "started" : "failed",
                  apConfigured ? "ok" : "failed", AP_SSID,
                  WiFi.softAPIP().toString().c_str(), poot::kApChannel,
                  poot::kApMaxConnections);
  return true;
}

void handleLocalUnlock() {
  // Route handler is registered inline in ensureHttpServer().
}

void setupWiFi() {
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.setSleepMode(WIFI_NONE_SLEEP);
  WiFi.mode(WIFI_AP_STA);
  poot_diag::logf("WIFI", "mode AP+STA");

  const bool apRestarted = ensureAccessPoint(true);
  ensureHttpServer(apRestarted);
  connectSta();
}

void pollCloudCommands() {
  if (localPriorityActive()) {
    logLocalPriorityHoldoff("CLOUD");
    return;
  }

  if (!isCloudReady()) {
    logCloudHoldoff("CLOUD");
    return;
  }

  const uint32_t nowMs = millis();
  if (nowMs - lastCloudPollMs < poot::kCloudPollMs) {
    return;
  }
  lastCloudPollMs = nowMs;

  FirebasePollResult poll;
  if (!firebase.pollCommands(poll) || !poll.ok) {
    const String reason =
        poll.error.isEmpty() ? firebase.lastError() : poll.error;
    const uint32_t nowMs = millis();
    if (reason != lastCloudPollFailureReason ||
        nowMs - lastCloudPollFailureLogMs >= 10000) {
      poot_diag::logf("CLOUD", "poll failed: %s",
                      reason.isEmpty() ? "unknown" : reason.c_str());
      lastCloudPollFailureReason = reason;
      lastCloudPollFailureLogMs = nowMs;
    }
    return;
  }

  lastCloudPollFailureReason = "";

  if (poll.count > 0) {
    poot_diag::logf("CLOUD", "poll commands=%u", static_cast<unsigned>(poll.count));
  }
  bool handledCommand = false;
  for (size_t i = 0; i < poll.count; i++) {
    const FirebaseCommand& cmd = poll.commands[i];
    if (cmd.commandId.isEmpty()) {
      continue;
    }
    if (hasProcessedCommand(cmd.commandId)) {
      poot_diag::logf("CLOUD", "skip duplicate command=%s", cmd.commandId.c_str());
      continue;
    }

    rememberProcessedCommand(cmd.commandId);
    poot_diag::logf("CLOUD", "process command=%s type=%s uid=%s",
                    cmd.commandId.c_str(), cmd.type.c_str(),
                    cmd.requestedByUid.c_str());

    if (!cmd.type.equalsIgnoreCase("unlock")) {
      poot_diag::logf("CLOUD", "ignored command=%s reason=unsupported_type",
                      cmd.commandId.c_str());
      const bool deleted = firebase.deleteCommand(cmd.commandId);
      poot_diag::logf("CLOUD", "cleanup command=%s reason=unsupported_type %s",
                      cmd.commandId.c_str(), deleted ? "deleted" : "delete_failed");
      handledCommand = true;
      break;
    }

    const bool fired =
        relay.triggerPulse(poot::kUnlockPulseMs, poot::kUnlockCooldownMs);
    poot_diag::logf("CLOUD", "unlock command=%s %s", cmd.commandId.c_str(),
                    fired ? "success" : "denied_cooldown");

    firebase.writeAudit("unlock", "cloud", fired ? "success" : "denied",
                        fired ? "ok" : "cooldown", cmd.commandId,
                        cmd.requestedByUid);
    const bool deleted = firebase.deleteCommand(cmd.commandId);
    poot_diag::logf("CLOUD", "cleanup command=%s reason=processed %s",
                    cmd.commandId.c_str(), deleted ? "deleted" : "delete_failed");
    handledCommand = true;
    break;
  }

  if (handledCommand) {
    // Process at most one new command per poll cycle to avoid secure request bursts.
    return;
  }
}

void publishHeartbeat() {
  if (localPriorityActive()) {
    logLocalPriorityHoldoff("CLOUD");
    return;
  }

  if (!isCloudReady()) {
    logCloudHoldoff("CLOUD");
    return;
  }

  const uint32_t nowMs = millis();
  if (nowMs - lastHeartbeatMs < poot::kHeartbeatMs) {
    return;
  }

  if (firebase.shouldSkipCloudWrites()) {
    const String reason =
        firebase.lastError().isEmpty() ? "auth_not_ready" : firebase.lastError();
    if (reason != lastHeartbeatSkipReason ||
        nowMs - lastHeartbeatSkipLogMs >= 10000) {
      poot_diag::logf("CLOUD", "heartbeat skipped: %s", reason.c_str());
      lastHeartbeatSkipReason = reason;
      lastHeartbeatSkipLogMs = nowMs;
    }
    lastHeartbeatMs = nowMs;
    return;
  }

  lastHeartbeatMs = nowMs;

  const bool ok = firebase.patchState(true,
                                      relay.isRelayOn() ? "unlocked" : "locked",
                                      poot::kFirmwareVersion);
  poot_diag::logf("CLOUD", "heartbeat %s", ok ? "ok" : "failed");
  if (ok) {
    lastHeartbeatSkipReason = "";
  }
}

void ensureNetworkStack() {
  const uint32_t nowMs = millis();
  if (nowMs - lastNetworkEnsureMs < poot::kNetworkEnsureMs) {
    return;
  }
  lastNetworkEnsureMs = nowMs;

  const bool apRestarted = ensureAccessPoint();
  if (apRestarted) {
    ensureHttpServer(true);
  } else if (!serverStarted) {
    ensureHttpServer();
  }

  if (localPriorityActive()) {
    logLocalPriorityHoldoff("WIFI");
    return;
  }

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
  delay(150);
  poot_diag::logf("BOOT", "Poot firmware booting version=%s",
                  poot::kFirmwareVersion);
  String resetReason = ESP.getResetReason();
  resetReason.toLowerCase();
  if (resetReason.indexOf("exception") >= 0 || resetReason.indexOf("wdt") >= 0) {
    cloudStartDelayMs = poot::kFirebaseRateLimitBackoffMs;
  }
  poot_diag::logf("BOOT", "reset reason=%s", ESP.getResetReason().c_str());
  poot_diag::logf("BOOT", "build timestamp=%s %s", __DATE__, __TIME__);
  poot_diag::logf(
      "BOOT",
      "cloud holdoff=%lu ms authTimeout(http=%lu ms socket=%lu ms) authBackoff(init=%lu ms max=%lu ms)",
      cloudStartDelayMs, poot::kFirebaseHttpTimeoutMs,
      poot::kFirebaseSocketTimeoutMs, poot::kFirebaseAuthRetryInitialMs,
      poot::kFirebaseAuthRetryMaxMs);
  randomSeed(analogRead(A0));
  poot_diag::logf("BOOT", "random seed initialized");

  setupStatusLed();
  relay.begin();
  poot_diag::logf("BOOT", "local auth=shared_key");
  poot_diag::logf("BOOT", "fixed STA ip=%s AP ip=%s",
                  kStaIp.toString().c_str(), kApIp.toString().c_str());

  setupWiFi();
  const bool firebaseReady = firebase.begin();
  poot_diag::logf("BOOT", "firebase=%s", firebaseReady ? "ok" : "failed");
}

void loop() {
  pumpLocalServer();
  relay.loop();

  logWiFiStatusIfChanged();
  ensureNetworkStack();
  pumpLocalServer();
  pollCloudCommands();
  pumpLocalServer();
  publishHeartbeat();
  pumpLocalServer();
  updateStatusLed();
  yield();
}
