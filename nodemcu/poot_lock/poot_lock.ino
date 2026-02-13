#include <Arduino.h>
#include <ArduinoJson.h>
#include <ESP8266WebServer.h>
#include <ESP8266WiFi.h>
#include <time.h>

#include "config.h"
#include "diagnostics.h"
#include "firebase_client.h"
#include "local_unlock.h"
#include "relay_control.h"
#include "secrets.h"
#include "storage.h"

Storage storage;
RelayController relay(poot::kRelayPin, poot::kRelayActiveLow);
FirebaseClient firebase;
ESP8266WebServer server(poot::kLocalHttpPort);

String processedCommandIds[16];
size_t processedCount = 0;

uint32_t lastCloudPollMs = 0;
uint32_t lastHeartbeatMs = 0;
uint32_t lastWiFiReconnectMs = 0;
uint32_t lastClockSyncMs = 0;
uint32_t lastWiFiBeginMs = 0;
uint32_t wifiConnectedSinceMs = 0;
uint32_t lastCloudHoldoffLogMs = 0;
uint32_t cloudStartDelayMs = poot::kCloudStartDelayAfterWiFiMs;
uint32_t lastCloudPollFailureLogMs = 0;
String lastCloudPollFailureReason;
uint32_t lastHeartbeatSkipLogMs = 0;
String lastHeartbeatSkipReason;

uint8_t buttonLastReading = HIGH;
uint8_t buttonStableState = HIGH;
uint32_t buttonLastEdgeMs = 0;
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

void setupExitButton() {
  pinMode(poot::kExitButtonPin, INPUT_PULLUP);
  buttonStableState = digitalRead(poot::kExitButtonPin);
  buttonLastReading = buttonStableState;
  buttonLastEdgeMs = millis();
  poot_diag::logf("BUTTON", "exit button initialized pin=%u activeLow=%u state=%u",
                  poot::kExitButtonPin, poot::kExitButtonActiveLow ? 1 : 0,
                  buttonStableState);
}

bool isButtonPressed(uint8_t state) {
  if (poot::kExitButtonActiveLow) {
    return state == LOW;
  }
  return state == HIGH;
}

void handleExitButton() {
  const uint32_t nowMs = millis();
  const uint8_t reading = digitalRead(poot::kExitButtonPin);

  if (reading != buttonLastReading) {
    buttonLastReading = reading;
    buttonLastEdgeMs = nowMs;
  }

  if (nowMs - buttonLastEdgeMs < poot::kExitButtonDebounceMs) {
    return;
  }

  if (buttonStableState == reading) {
    return;
  }

  buttonStableState = reading;
  if (!isButtonPressed(buttonStableState)) {
    return;
  }

  poot_diag::logf("BUTTON", "press detected");
  const bool fired =
      relay.triggerPulse(poot::kUnlockPulseMs, poot::kUnlockCooldownMs);
  poot_diag::logf("BUTTON", "unlock %s", fired ? "success" : "denied_cooldown");
  firebase.writeAudit("unlock", "button", fired ? "success" : "denied",
                      fired ? "ok" : "cooldown", "", "");
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

uint32_t bestEffortNow() {
  const time_t rtcNow = time(nullptr);
  if (rtcNow > 100000) {
    return static_cast<uint32_t>(rtcNow);
  }
  return local_unlock::approximateNow();
}

void refreshClockAnchor() {
  const uint32_t now = static_cast<uint32_t>(time(nullptr));
  if (now > 100000) {
    local_unlock::setClockAnchor(now);
    poot_diag::logf("CLOCK", "NTP anchor refreshed now=%lu", now);
  } else {
    poot_diag::logf("CLOCK", "NTP not ready yet");
  }
}

void connectSta() {
  if (WiFi.status() == WL_CONNECTED) {
    return;
  }

  lastWiFiBeginMs = millis();
  poot_diag::logf("WIFI", "STA connecting to ssid=%s", WIFI_STA_SSID);
  WiFi.begin(WIFI_STA_SSID, WIFI_STA_PASSWORD);
}

template <typename TDoc>
void sendJson(int code, const TDoc& doc) {
  String body;
  serializeJson(doc, body);
  server.send(code, "application/json", body);
}

void handleLocalUnlock() {
  StaticJsonDocument<256> response;
  const String remoteIp = server.client().remoteIP().toString();
  poot_diag::logf("LOCAL_HTTP", "POST /api/local-unlock from %s",
                  remoteIp.c_str());

  if (!server.hasArg("plain")) {
    poot_diag::logf("LOCAL_HTTP", "bad_request: missing body");
    response["ok"] = false;
    response["code"] = "bad_request";
    response["message"] = "Missing JSON body";
    sendJson(400, response);
    return;
  }

  StaticJsonDocument<256> requestDoc;
  const auto err = deserializeJson(requestDoc, server.arg("plain"));
  if (err) {
    poot_diag::logf("LOCAL_HTTP", "bad_json: parse failed");
    response["ok"] = false;
    response["code"] = "bad_json";
    response["message"] = "Could not parse JSON";
    sendJson(400, response);
    return;
  }

  LocalUnlockRequest req;
  req.ts = requestDoc["ts"] | 0;
  req.sig = requestDoc["sig"] | "";
  poot_diag::logf("LOCAL_HTTP", "request ts=%lu sigLen=%u", req.ts,
                  req.sig.length());

  const ValidationResult validation = local_unlock::validate(req);
  if (!validation.ok) {
    poot_diag::logf("LOCAL_HTTP", "unlock denied reason=%s",
                    validation.reason.c_str());
    firebase.writeAudit("unlock", "local", "denied", validation.reason, "",
                        "");
    response["ok"] = false;
    response["code"] = validation.reason;
    response["message"] = "Local unlock denied";
    sendJson(401, response);
    return;
  }

  const bool fired = relay.triggerPulse(poot::kUnlockPulseMs, poot::kUnlockCooldownMs);
  const String reason = fired ? "ok" : "cooldown";
  poot_diag::logf("LOCAL_HTTP", "unlock %s", fired ? "success" : "denied_cooldown");
  firebase.writeAudit("unlock", "local", fired ? "success" : "denied", reason,
                      "", "");

  response["ok"] = fired;
  response["code"] = reason;
  response["message"] = fired ? "Unlocked" : "Relay cooldown active";
  sendJson(fired ? 200 : 429, response);
}

void handleLocalTime() {
  StaticJsonDocument<192> response;

  uint32_t nowSec = local_unlock::approximateNow();
  if (nowSec > 0) {
    poot_diag::logf("LOCAL_HTTP", "GET /api/local-time source=anchor now=%lu",
                    nowSec);
    response["ok"] = true;
    response["ts"] = nowSec;
    response["windowSec"] = poot::kTimestampWindowSec;
    response["source"] = "anchor";
    sendJson(200, response);
    return;
  }

  const uint32_t rtcNow = static_cast<uint32_t>(time(nullptr));
  if (rtcNow > 100000) {
    // Keep local validator aligned with RTC when available.
    local_unlock::setClockAnchor(rtcNow);
    poot_diag::logf("LOCAL_HTTP", "GET /api/local-time source=rtc now=%lu",
                    rtcNow);
    response["ok"] = true;
    response["ts"] = rtcNow;
    response["windowSec"] = poot::kTimestampWindowSec;
    response["source"] = "rtc";
    sendJson(200, response);
    return;
  }

  poot_diag::logf("LOCAL_HTTP", "GET /api/local-time failed: no_clock");
  response["ok"] = false;
  response["code"] = "no_clock";
  response["message"] = "Device clock unavailable";
  sendJson(503, response);
}

void setupServer() {
  server.on("/", HTTP_GET, []() {
    poot_diag::logf("HTTP", "GET /");
    server.send(200, "text/plain", "Poot lock online");
  });

  server.on("/api/local-time", HTTP_GET, handleLocalTime);
  server.on("/api/local-unlock", HTTP_POST, handleLocalUnlock);

  server.onNotFound([]() {
    poot_diag::logf("HTTP", "404 %s", server.uri().c_str());
    StaticJsonDocument<128> response;
    response["ok"] = false;
    response["code"] = "not_found";
    response["message"] = "Route not found";
    sendJson(404, response);
  });

  server.begin();
  poot_diag::logf("HTTP", "server started on port=%u", poot::kLocalHttpPort);
}

void setupWiFi() {
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.setSleepMode(WIFI_NONE_SLEEP);
  WiFi.mode(WIFI_AP_STA);
  poot_diag::logf("WIFI", "mode AP+STA");

  const bool apStarted = WiFi.softAP(AP_SSID, AP_PASSWORD, poot::kApChannel,
                                     false, poot::kApMaxConnections);
  poot_diag::logf("WIFI", "AP %s ssid=%s ip=%s channel=%u maxClients=%u",
                  apStarted ? "started" : "failed", AP_SSID,
                  WiFi.softAPIP().toString().c_str(), poot::kApChannel,
                  poot::kApMaxConnections);
  connectSta();
}

bool isUnlockCommandFresh(const FirebaseCommand& cmd) {
  if (cmd.expiresAt == 0) {
    return true;
  }

  const uint32_t now = bestEffortNow();
  if (now == 0) {
    poot_diag::logf("CLOUD", "command=%s freshness check skipped (no clock)",
                    cmd.commandId.c_str());
    return true;
  }
  const bool fresh = now <= cmd.expiresAt;
  if (!fresh) {
    poot_diag::logf("CLOUD", "command=%s expired now=%lu expiresAt=%lu",
                    cmd.commandId.c_str(), now, cmd.expiresAt);
  }
  return fresh;
}

void pollCloudCommands() {
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
      if (!isUnlockCommandFresh(cmd)) {
        const bool deleted = firebase.deleteCommand(cmd.commandId);
        poot_diag::logf("CLOUD", "cleanup command=%s reason=expired_duplicate %s",
                        cmd.commandId.c_str(),
                        deleted ? "deleted" : "delete_failed");
        handledCommand = true;
        break;
      }
      poot_diag::logf("CLOUD", "skip duplicate command=%s", cmd.commandId.c_str());
      continue;
    }

    rememberProcessedCommand(cmd.commandId);
    poot_diag::logf("CLOUD", "process command=%s type=%s expiresAt=%lu uid=%s",
                    cmd.commandId.c_str(), cmd.type.c_str(), cmd.expiresAt,
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

    if (!isUnlockCommandFresh(cmd)) {
      poot_diag::logf("CLOUD", "denied command=%s reason=command_expired",
                      cmd.commandId.c_str());
      const bool deleted = firebase.deleteCommand(cmd.commandId);
      poot_diag::logf("CLOUD", "cleanup command=%s reason=command_expired %s",
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

void maybeReconnectWiFi() {
  if (WiFi.status() == WL_CONNECTED) {
    return;
  }

  const uint32_t nowMs = millis();
  if (nowMs - lastWiFiReconnectMs < poot::kWiFiReconnectMs) {
    return;
  }

  lastWiFiReconnectMs = nowMs;
  poot_diag::logf("WIFI", "reconnect attempt");
  connectSta();
}

void maybeSyncClock() {
  const uint32_t nowMs = millis();
  if (nowMs - lastClockSyncMs < 60000) {
    return;
  }
  lastClockSyncMs = nowMs;

  refreshClockAnchor();
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
  setupExitButton();
  const bool storageReady = storage.begin();
  poot_diag::logf("BOOT", "storage=%s", storageReady ? "ok" : "failed");
  firebase.setStorage(&storage);
  poot_diag::logf("BOOT", "local timestamp window=%lu s",
                  poot::kTimestampWindowSec);
  poot_diag::logf("BOOT", "persisted cloud cooldown until=%lu",
                  firebase.cloudCooldownUntilEpoch());
  relay.begin();

  local_unlock::begin(&storage, LOCAL_SHARED_SECRET, poot::kTimestampWindowSec,
                      poot::kReplayRetentionSec, poot::kReplayCacheSize);

  setupWiFi();

  configTime(0, 0, "pool.ntp.org", "time.nist.gov", "time.google.com");
  poot_diag::logf("CLOCK", "NTP configured");
  refreshClockAnchor();

  setupServer();
  const bool firebaseReady = firebase.begin();
  poot_diag::logf("BOOT", "firebase=%s", firebaseReady ? "ok" : "failed");
}

void loop() {
  server.handleClient();
  relay.loop();
  handleExitButton();

  logWiFiStatusIfChanged();
  maybeReconnectWiFi();
  maybeSyncClock();
  pollCloudCommands();
  publishHeartbeat();
  updateStatusLed();
  yield();
}
