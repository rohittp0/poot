#include "firebase_client.h"

#include <ArduinoJson.h>
#include <ESP8266HTTPClient.h>
#include <ESP8266WiFi.h>
#include <WiFiClientSecureBearSSL.h>
#include <new>
#include <time.h>

#include "config.h"
#include "diagnostics.h"
#include "secrets.h"
#include "storage.h"

namespace {

String extractFirebaseError(const String& body) {
  DynamicJsonDocument doc(512);
  if (deserializeJson(doc, body)) {
    return "";
  }

  if (doc["error"]["message"].is<const char*>()) {
    return doc["error"]["message"].as<const char*>();
  }

  if (doc["error"].is<const char*>()) {
    return doc["error"].as<const char*>();
  }

  return "";
}

bool millisBefore(uint32_t nowMs, uint32_t targetMs) {
  return static_cast<int32_t>(nowMs - targetMs) < 0;
}

bool isFirebaseCredentialError(const String& err) {
  if (err.indexOf("INVALID_LOGIN_CREDENTIALS") >= 0) {
    return true;
  }
  if (err.indexOf("INVALID_PASSWORD") >= 0) {
    return true;
  }
  if (err.indexOf("EMAIL_NOT_FOUND") >= 0) {
    return true;
  }
  if (err.indexOf("USER_DISABLED") >= 0) {
    return true;
  }
  return false;
}

bool isFirebaseRateLimitError(const String& err) {
  return err.indexOf("TOO_MANY_ATTEMPTS_TRY_LATER") >= 0;
}

#ifndef BEARSSL_SSL_BASIC
static const uint16_t kPootTlsSuites[] PROGMEM = {
    BR_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
    BR_TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    BR_TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256,
    BR_TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256,
    BR_TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,
    BR_TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA,
    BR_TLS_RSA_WITH_AES_128_CBC_SHA256,
    BR_TLS_RSA_WITH_AES_128_CBC_SHA,
};
#endif

}  // namespace

void FirebaseClient::setStorage(Storage* storage) {
  storage_ = storage;
  loadPersistedCooldown();
}

uint32_t FirebaseClient::cloudCooldownUntilEpoch() const {
  return cloudCooldownUntilEpoch_;
}

void FirebaseClient::loadPersistedCooldown() {
  cooldownLoaded_ = true;
  cloudCooldownUntilEpoch_ = 0;
  fallbackClockAnchorEpoch_ = 0;
  fallbackClockAnchorMillis_ = millis();

  if (storage_ == nullptr) {
    return;
  }

  uint32_t cooldownUntil = 0;
  if (storage_->loadCloudCooldownUntil(cooldownUntil)) {
    cloudCooldownUntilEpoch_ = cooldownUntil;
  }

  uint32_t clockAnchor = 0;
  if (storage_->loadClockAnchor(clockAnchor)) {
    fallbackClockAnchorEpoch_ = clockAnchor;
    fallbackClockAnchorMillis_ = millis();
  }

  poot_diag::logf("FIREBASE", "loaded cooldownUntil=%lu fallbackAnchor=%lu",
                  cloudCooldownUntilEpoch_, fallbackClockAnchorEpoch_);
}

uint32_t FirebaseClient::effectiveNowEpoch() const {
  const uint32_t now = static_cast<uint32_t>(time(nullptr));
  if (now > 100000) {
    return now;
  }

  if (fallbackClockAnchorEpoch_ > 100000) {
    const uint32_t elapsed = (millis() - fallbackClockAnchorMillis_) / 1000;
    return fallbackClockAnchorEpoch_ + elapsed;
  }

  return 0;
}

bool FirebaseClient::cooldownActive(uint32_t nowEpoch) const {
  if (cloudCooldownUntilEpoch_ == 0) {
    return false;
  }
  if (nowEpoch == 0) {
    return true;
  }
  return nowEpoch < cloudCooldownUntilEpoch_;
}

void FirebaseClient::setCloudCooldownUntil(uint32_t untilEpoch,
                                           const char* reason) {
  cloudCooldownUntilEpoch_ = untilEpoch;
  if (storage_ != nullptr) {
    storage_->saveCloudCooldownUntil(cloudCooldownUntilEpoch_);
  }
  poot_diag::logf("FIREBASE", "cooldown until=%lu reason=%s",
                  cloudCooldownUntilEpoch_, reason);
}

void FirebaseClient::clearCloudCooldown() {
  if (cloudCooldownUntilEpoch_ == 0) {
    return;
  }

  cloudCooldownUntilEpoch_ = 0;
  if (storage_ != nullptr) {
    storage_->saveCloudCooldownUntil(0);
  }
  poot_diag::logf("FIREBASE", "cooldown cleared");
}

bool FirebaseClient::begin() {
  poot_diag::logf("FIREBASE", "client begin");

  if (!cooldownLoaded_) {
    loadPersistedCooldown();
  }

  if (WiFi.status() != WL_CONNECTED) {
    lastError_ = "wifi_disconnected";
    poot_diag::logf("FIREBASE", "wifi not connected, auth deferred");
    return false;
  }

  const bool ok = ensureSignedIn(false);
  poot_diag::logf("FIREBASE", "client ready=%u", ok ? 1 : 0);
  return ok;
}

bool FirebaseClient::ensureSignedIn(bool allowActiveAuth) {
  if (!cooldownLoaded_) {
    loadPersistedCooldown();
  }

  if (WiFi.status() != WL_CONNECTED) {
    lastError_ = "wifi_disconnected";
    return false;
  }

  const uint32_t nowEpoch = effectiveNowEpoch();
  if (cooldownActive(nowEpoch)) {
    lastError_ = "auth_backoff";
    return false;
  }

  if (credentialsRejected_) {
    lastError_ = "invalid_device_credentials";
    return false;
  }

  const uint32_t nowMs = millis();
  if (authBackoffActive(nowMs)) {
    lastError_ = "auth_backoff";
    return false;
  }

  if (idToken_.isEmpty()) {
    if (!allowActiveAuth) {
      lastError_ = "auth_required";
      return false;
    }
    poot_diag::logf("FIREBASE", "no id token, signing in");
    const bool ok = signInWithPassword();
    recordAuthResult(ok, "sign-in");
    return ok;
  }

  if (tokenExpiringSoon()) {
    if (!allowActiveAuth) {
      lastError_ = "auth_refresh_required";
      return false;
    }
    poot_diag::logf("FIREBASE", "id token expiring soon, refreshing");
    if (refreshToken_.isEmpty()) {
      poot_diag::logf("FIREBASE", "refresh token missing, signing in");
      const bool ok = signInWithPassword();
      recordAuthResult(ok, "sign-in");
      return ok;
    }

    const bool ok = refreshIdToken();
    recordAuthResult(ok, "refresh");
    if (!ok) {
      // Retry with full sign-in on the next poll cycle.
      idToken_ = "";
      poot_diag::logf("FIREBASE", "refresh failed, sign-in deferred");
    }
    return ok;
  }

  return true;
}

bool FirebaseClient::authBackoffActive(uint32_t nowMs) const {
  if (nextAuthAttemptMs_ == 0) {
    return false;
  }
  return millisBefore(nowMs, nextAuthAttemptMs_);
}

uint32_t FirebaseClient::secureSpacingRemainingMs(uint32_t nowMs) const {
  if (nextSecureRequestAllowedMs_ == 0) {
    return 0;
  }
  if (!millisBefore(nowMs, nextSecureRequestAllowedMs_)) {
    return 0;
  }
  return nextSecureRequestAllowedMs_ - nowMs;
}

bool FirebaseClient::shouldSkipCloudWrites() const {
  const uint32_t nowMs = millis();
  if (WiFi.status() != WL_CONNECTED) {
    return true;
  }
  if (idToken_.isEmpty()) {
    return true;
  }
  if (authBackoffActive(nowMs)) {
    return true;
  }
  if (cooldownActive(effectiveNowEpoch())) {
    return true;
  }
  return false;
}

void FirebaseClient::applyAuthBackoffMs(uint32_t backoffMs, const char* reason) {
  if (backoffMs < poot::kFirebaseAuthRetryInitialMs) {
    backoffMs = poot::kFirebaseAuthRetryInitialMs;
  }
  nextAuthAttemptMs_ = millis() + backoffMs;
  authBackoffMs_ = backoffMs;

  const uint32_t nowMs = millis();
  if (nowMs - lastAuthBackoffLogMs_ >= poot::kFirebaseAuthBackoffLogMs) {
    poot_diag::logf("FIREBASE", "auth backoff reason=%s retryIn=%lu s", reason,
                    (backoffMs + 999) / 1000);
    lastAuthBackoffLogMs_ = nowMs;
  }
}

void FirebaseClient::recordAuthResult(bool success, const char* opName) {
  if (success) {
    nextAuthAttemptMs_ = 0;
    authBackoffMs_ = poot::kFirebaseAuthRetryInitialMs;
    credentialsRejected_ = false;
    clearCloudCooldown();
    return;
  }

  if (authBackoffMs_ < poot::kFirebaseAuthRetryInitialMs) {
    authBackoffMs_ = poot::kFirebaseAuthRetryInitialMs;
  }

  applyAuthBackoffMs(authBackoffMs_, opName);

  if (authBackoffMs_ < poot::kFirebaseAuthRetryMaxMs) {
    authBackoffMs_ *= 2;
    if (authBackoffMs_ > poot::kFirebaseAuthRetryMaxMs) {
      authBackoffMs_ = poot::kFirebaseAuthRetryMaxMs;
    }
  }
}

bool FirebaseClient::pollCommands(FirebasePollResult& out) {
  out = FirebasePollResult{};

  if (!ensureSignedIn(true)) {
    out.error = lastError_;
    if (!(out.error == "auth_backoff" || out.error == "secure_spacing" ||
          out.error == "low_heap" ||
          out.error == "wifi_disconnected" || out.error == "auth_required" ||
          out.error == "auth_refresh_required")) {
      poot_diag::logf("FIREBASE", "poll denied, not signed in: %s",
                      out.error.c_str());
    }
    return false;
  }

  const String path = String("/locks/") + LOCK_ID +
                      "/commands.json?orderBy=%22$key%22&limitToLast=" +
                      String(poot::kCommandFetchLimit) + "&auth=" + idToken_;
  const String url = databaseUrl(path);

  String body;
  int httpCode = 0;
  if (!doJsonRequest("GET", url, "", body, httpCode)) {
    out.error = lastError_;
    if (!(out.error == "auth_backoff" || out.error == "secure_spacing" ||
          out.error == "low_heap" ||
          out.error == "wifi_disconnected")) {
      poot_diag::logf("FIREBASE", "poll request failed: %s", out.error.c_str());
    }
    return false;
  }

  if (httpCode == 401 || httpCode == 403) {
    const String fbErr = extractFirebaseError(body);
    idToken_ = "";
    refreshToken_ = "";
    tokenExpiryEpoch_ = 0;
    lastError_ = "unauthorized";
    const uint32_t nowEpoch = effectiveNowEpoch();
    if (nowEpoch > 100000) {
      setCloudCooldownUntil(
          nowEpoch + (poot::kFirebaseUnauthorizedBackoffMs / 1000),
          "unauthorized");
    } else {
      poot_diag::logf(
          "FIREBASE",
          "unauthorized cooldown not persisted (no clock), using RAM backoff only");
    }
    applyAuthBackoffMs(poot::kFirebaseUnauthorizedBackoffMs, "unauthorized");
    out.error = "unauthorized";
    poot_diag::logf("FIREBASE", "poll unauthorized http=%d err=%s", httpCode,
                    fbErr.isEmpty() ? "unknown" : fbErr.c_str());
    return false;
  }

  DynamicJsonDocument doc(8192);
  const auto err = deserializeJson(doc, body);
  if (err) {
    out.error = "invalid_json";
    lastError_ = out.error;
    poot_diag::logf("FIREBASE", "poll JSON invalid");
    return false;
  }

  if (doc.isNull()) {
    out.ok = true;
    poot_diag::logf("FIREBASE", "poll ok: 0 commands");
    return true;
  }

  if (doc["error"].is<const char*>()) {
    out.error = doc["error"].as<const char*>();
    lastError_ = out.error;
    poot_diag::logf("FIREBASE", "poll firebase error: %s", out.error.c_str());
    return false;
  }

  JsonObject obj = doc.as<JsonObject>();
  for (JsonPair kv : obj) {
    if (out.count >= 8) {
      break;
    }

    JsonObject cmd = kv.value().as<JsonObject>();
    if (cmd.isNull()) {
      continue;
    }

    FirebaseCommand parsed;
    parsed.commandId = kv.key().c_str();
    parsed.type = cmd["type"] | "";
    parsed.createdAt = cmd["createdAt"] | 0;
    parsed.expiresAt = cmd["expiresAt"] | 0;
    parsed.requestedByUid = cmd["requestedByUid"] | "";
    parsed.channel = cmd["channel"] | "";

    out.commands[out.count++] = parsed;
  }

  out.ok = true;
  poot_diag::logf("FIREBASE", "poll ok: commands=%u",
                  static_cast<unsigned>(out.count));
  return true;
}

bool FirebaseClient::patchState(bool online, const String& relayState,
                                const String& fwVersion) {
  if (!ensureSignedIn(false)) {
    return false;
  }

  StaticJsonDocument<256> doc;
  doc["online"] = online;
  doc["lastSeen"] = static_cast<uint32_t>(time(nullptr));
  doc["relayState"] = relayState;
  doc["fwVersion"] = fwVersion;

  String payload;
  serializeJson(doc, payload);

  const String url = databaseUrl(String("/locks/") + LOCK_ID +
                                 "/state.json?auth=" + idToken_);

  String body;
  int code = 0;
  if (!doJsonRequest("PATCH", url, payload, body, code)) {
    poot_diag::logf("FIREBASE", "patch state request failed: %s",
                    lastError_.c_str());
    return false;
  }

  if (code >= 200 && code < 300) {
    poot_diag::logf("FIREBASE", "patch state ok");
    return true;
  }

  lastError_ = "state_patch_failed";
  const String fbErr = extractFirebaseError(body);
  poot_diag::logf("FIREBASE", "patch state failed http=%d err=%s", code,
                  fbErr.isEmpty() ? "unknown" : fbErr.c_str());
  return false;
}

bool FirebaseClient::deleteCommand(const String& commandId) {
  if (commandId.isEmpty()) {
    lastError_ = "invalid_command_id";
    return false;
  }
  if (!ensureSignedIn(false)) {
    return false;
  }

  const String url = databaseUrl(String("/locks/") + LOCK_ID + "/commands/" +
                                 commandId + ".json?auth=" + idToken_);

  String body;
  int code = 0;
  if (!doJsonRequest("DELETE", url, "", body, code)) {
    poot_diag::logf("FIREBASE", "delete command request failed id=%s err=%s",
                    commandId.c_str(), lastError_.c_str());
    return false;
  }

  if (code >= 200 && code < 300) {
    poot_diag::logf("FIREBASE", "delete command ok id=%s", commandId.c_str());
    return true;
  }

  lastError_ = "command_delete_failed";
  const String fbErr = extractFirebaseError(body);
  poot_diag::logf("FIREBASE", "delete command failed id=%s http=%d err=%s",
                  commandId.c_str(), code,
                  fbErr.isEmpty() ? "unknown" : fbErr.c_str());
  return false;
}

bool FirebaseClient::writeAudit(const String& action, const String& channel,
                                const String& result, const String& reason,
                                const String& commandId,
                                const String& actorUid) {
  if (!ensureSignedIn(false)) {
    return false;
  }

  const String eventId = String("evt_") + String(millis()) + "_" +
                         String(random(1000, 9999));

  StaticJsonDocument<384> doc;
  doc["ts"] = static_cast<uint32_t>(time(nullptr));
  doc["action"] = action;
  doc["channel"] = channel;
  doc["result"] = result;
  doc["reason"] = reason;
  doc["commandId"] = commandId;
  doc["actorUid"] = actorUid;

  String payload;
  serializeJson(doc, payload);

  const String url = databaseUrl(String("/locks/") + LOCK_ID + "/audit/" +
                                 eventId + ".json?auth=" + idToken_);

  String body;
  int code = 0;
  if (!doJsonRequest("PUT", url, payload, body, code)) {
    poot_diag::logf("FIREBASE", "write audit request failed: %s",
                    lastError_.c_str());
    return false;
  }

  if (code >= 200 && code < 300) {
    poot_diag::logf("FIREBASE", "audit ok action=%s channel=%s result=%s",
                    action.c_str(), channel.c_str(), result.c_str());
    return true;
  }

  lastError_ = "audit_write_failed";
  const String fbErr = extractFirebaseError(body);
  poot_diag::logf("FIREBASE", "audit failed http=%d err=%s", code,
                  fbErr.isEmpty() ? "unknown" : fbErr.c_str());
  return false;
}

const String& FirebaseClient::lastError() const { return lastError_; }

bool FirebaseClient::signInWithPassword() {
  poot_diag::logf("FIREBASE", "sign-in with device credentials");
  StaticJsonDocument<256> doc;
  doc["email"] = FIREBASE_DEVICE_EMAIL;
  doc["password"] = FIREBASE_DEVICE_PASSWORD;
  doc["returnSecureToken"] = true;

  String payload;
  serializeJson(doc, payload);

  const String url = String("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=") +
                     FIREBASE_API_KEY;

  String body;
  int code = 0;
  if (!doJsonRequest("POST", url, payload, body, code)) {
    poot_diag::logf("FIREBASE", "sign-in request failed: %s",
                    lastError_.c_str());
    return false;
  }

  if (code < 200 || code >= 300) {
    const String fbErr = extractFirebaseError(body);
    if (code == 400 && isFirebaseRateLimitError(fbErr)) {
      lastError_ = "auth_rate_limited";
      credentialsRejected_ = false;
      authBackoffMs_ = poot::kFirebaseRateLimitBackoffMs;
      const uint32_t nowEpoch = effectiveNowEpoch();
      if (nowEpoch > 100000) {
        setCloudCooldownUntil(
            nowEpoch + (poot::kFirebaseRateLimitBackoffMs / 1000),
            "rate_limited");
      } else {
        poot_diag::logf("FIREBASE", "rate limit cooldown not persisted (no clock)");
      }
    } else if (code == 400 &&
               (fbErr.isEmpty() || isFirebaseCredentialError(fbErr))) {
      lastError_ = "invalid_device_credentials";
      credentialsRejected_ = true;
      authBackoffMs_ = poot::kFirebaseAuthRetryMaxMs * 2;
    } else {
      lastError_ = "sign_in_failed_" + String(code);
    }
    poot_diag::logf("FIREBASE", "sign-in failed http=%d err=%s", code,
                    fbErr.isEmpty() ? "unknown" : fbErr.c_str());
    return false;
  }

  DynamicJsonDocument response(2048);
  const auto err = deserializeJson(response, body);
  if (err) {
    lastError_ = "sign_in_json_invalid";
    poot_diag::logf("FIREBASE", "sign-in failed: invalid JSON response");
    return false;
  }

  idToken_ = response["idToken"] | "";
  refreshToken_ = response["refreshToken"] | "";
  const uint32_t expiresInSec = String(response["expiresIn"] | "3600").toInt();

  const uint32_t now = static_cast<uint32_t>(time(nullptr));
  if (now > 100000) {
    tokenExpiryEpoch_ = now + expiresInSec;
  } else {
    tokenExpiryEpoch_ = 0;
  }

  if (idToken_.isEmpty()) {
    lastError_ = "missing_id_token";
    poot_diag::logf("FIREBASE", "sign-in failed: missing id token");
    return false;
  }

  lastError_ = "";
  poot_diag::logf("FIREBASE", "sign-in success");
  return true;
}

bool FirebaseClient::refreshIdToken() {
  if (refreshToken_.isEmpty()) {
    lastError_ = "missing_refresh_token";
    poot_diag::logf("FIREBASE", "refresh skipped: no refresh token");
    return false;
  }

  poot_diag::logf("FIREBASE", "refreshing id token");

  const String payload = String("grant_type=refresh_token&refresh_token=") +
                         refreshToken_;

  const String url = String("https://securetoken.googleapis.com/v1/token?key=") +
                     FIREBASE_API_KEY;

  String body;
  int code = 0;
  if (!doJsonRequest("POST", url, payload, body, code, true,
                     "application/x-www-form-urlencoded")) {
    poot_diag::logf("FIREBASE", "refresh request failed: %s",
                    lastError_.c_str());
    return false;
  }

  if (code < 200 || code >= 300) {
    lastError_ = "refresh_failed_" + String(code);
    const String fbErr = extractFirebaseError(body);
    poot_diag::logf("FIREBASE", "refresh failed http=%d err=%s", code,
                    fbErr.isEmpty() ? "unknown" : fbErr.c_str());
    return false;
  }

  DynamicJsonDocument response(2048);
  const auto err = deserializeJson(response, body);
  if (err) {
    lastError_ = "refresh_json_invalid";
    poot_diag::logf("FIREBASE", "refresh failed: invalid JSON response");
    return false;
  }

  idToken_ = response["id_token"] | "";
  refreshToken_ = response["refresh_token"] | "";
  const uint32_t expiresInSec = String(response["expires_in"] | "3600").toInt();

  const uint32_t now = static_cast<uint32_t>(time(nullptr));
  if (now > 100000) {
    tokenExpiryEpoch_ = now + expiresInSec;
  } else {
    tokenExpiryEpoch_ = 0;
  }

  const bool ok = !idToken_.isEmpty();
  if (ok) {
    lastError_ = "";
  }
  poot_diag::logf("FIREBASE", "refresh %s", ok ? "success" : "failed");
  return ok;
}

bool FirebaseClient::tokenExpiringSoon() const {
  if (idToken_.isEmpty()) {
    return true;
  }

  if (tokenExpiryEpoch_ == 0) {
    return false;
  }

  const uint32_t now = static_cast<uint32_t>(time(nullptr));
  if (now < 100000) {
    return false;
  }

  return now + poot::kFirebaseTokenRefreshSkewSec >= tokenExpiryEpoch_;
}

bool FirebaseClient::doJsonRequest(const String& method, const String& url,
                                   const String& payload, String& body,
                                   int& httpCode, bool secure,
                                   const String& contentType) {
  body = "";
  httpCode = 0;
  yield();

  if (secure) {
    const uint32_t nowMs = millis();
    const uint32_t waitMs = secureSpacingRemainingMs(nowMs);
    if (waitMs > 0) {
      if (waitMs >= 1000 && nowMs - lastSecureRequestGapLogMs_ >=
                               poot::kFirebaseAuthBackoffLogMs) {
        poot_diag::logf("FIREBASE",
                        "secure request deferred: spacing=%lu ms", waitMs);
        lastSecureRequestGapLogMs_ = nowMs;
      }
      delay(waitMs);
      yield();
    }
  }

  const uint32_t freeHeap = ESP.getFreeHeap();
  const uint32_t maxBlock = ESP.getMaxFreeBlockSize();
  if (secure && (freeHeap < poot::kFirebaseMinFreeHeapBytes ||
                 maxBlock < poot::kFirebaseMinMaxBlockBytes)) {
    lastError_ = "low_heap";
    applyAuthBackoffMs(poot::kFirebaseLowHeapBackoffMs, "low_heap");
    const uint32_t nowEpoch = effectiveNowEpoch();
    if (nowEpoch > 100000) {
      setCloudCooldownUntil(nowEpoch + (poot::kFirebaseLowHeapBackoffMs / 1000),
                            "low_heap");
    }
    poot_diag::logf(
        "FIREBASE",
        "skip secure request: low heap free=%lu maxBlock=%lu minFree=%lu minBlock=%lu",
        freeHeap, maxBlock, poot::kFirebaseMinFreeHeapBytes,
        poot::kFirebaseMinMaxBlockBytes);
    return false;
  }

  poot_diag::logf("FIREBASE", "request %s secure=%u free=%lu maxBlock=%lu",
                  method.c_str(), secure ? 1 : 0, freeHeap, maxBlock);

  HTTPClient http;
  http.setReuse(false);
  http.useHTTP10(true);
  http.setTimeout(poot::kFirebaseHttpTimeoutMs);

  if (secure) {
    nextSecureRequestAllowedMs_ = millis() + poot::kFirebaseSecureRequestGapMs;
    BearSSL::WiFiClientSecure* secureClient =
        new (std::nothrow) BearSSL::WiFiClientSecure();
    if (secureClient == nullptr) {
      lastError_ = "low_heap";
      applyAuthBackoffMs(poot::kFirebaseLowHeapBackoffMs, "low_heap");
      poot_diag::logf("FIREBASE", "secure client alloc failed");
      return false;
    }
    secureClient->setInsecure();
    secureClient->setTimeout(poot::kFirebaseSocketTimeoutMs);
    secureClient->setSSLVersion(BR_TLS12, BR_TLS12);
    secureClient->setBufferSizes(poot::kFirebaseTlsRxBufferBytes,
                                 poot::kFirebaseTlsTxBufferBytes);
#ifndef BEARSSL_SSL_BASIC
    if (!secureClient->setCiphers(kPootTlsSuites,
                                  sizeof(kPootTlsSuites) /
                                      sizeof(kPootTlsSuites[0]))) {
      poot_diag::logf("FIREBASE", "TLS cipher config failed, using defaults");
    }
#endif
    secureClient->stop();
    if (!http.begin(*secureClient, url)) {
      lastError_ = "http_begin_failed";
      poot_diag::logf("FIREBASE", "http.begin failed (secure)");
      secureClient->stop();
      delete secureClient;
      return false;
    }

    http.addHeader("Content-Type", contentType);

    if (method == "GET") {
      httpCode = http.GET();
    } else {
      httpCode = http.sendRequest(method.c_str(), payload);
    }
    yield();

    if (httpCode > 0) {
      body = http.getString();
    }
    yield();
    http.end();
    secureClient->stop();
    delete secureClient;
    yield();
    if (httpCode <= 0) {
      lastError_ = "http_request_failed";
      const String err = http.errorToString(httpCode);
      poot_diag::logf("FIREBASE", "HTTP request failed method=%s code=%d err=%s",
                      method.c_str(), httpCode, err.c_str());
    }
    return httpCode > 0;
  }

  WiFiClient client;
  client.setTimeout(poot::kFirebaseSocketTimeoutMs);
  if (!http.begin(client, url)) {
    lastError_ = "http_begin_failed";
    poot_diag::logf("FIREBASE", "http.begin failed (insecure)");
    return false;
  }

  http.addHeader("Content-Type", contentType);

  if (method == "GET") {
    httpCode = http.GET();
  } else {
    httpCode = http.sendRequest(method.c_str(), payload);
  }
  yield();

  if (httpCode > 0) {
    body = http.getString();
  }
  yield();
  http.end();
  yield();
  if (httpCode <= 0) {
    lastError_ = "http_request_failed";
    const String err = http.errorToString(httpCode);
    poot_diag::logf("FIREBASE", "HTTP request failed method=%s code=%d err=%s",
                    method.c_str(), httpCode, err.c_str());
  }
  return httpCode > 0;
}

String FirebaseClient::databaseUrl(const String& path) const {
  return String(FIREBASE_DB_URL) + path;
}
