#pragma once

#include <Arduino.h>

#include "config.h"

struct FirebaseCommand {
  String commandId;
  String type;
  uint32_t createdAt = 0;
  uint32_t expiresAt = 0;
  String requestedByUid;
  String channel;
};

struct FirebasePollResult {
  bool ok = false;
  String error;
  FirebaseCommand commands[8];
  size_t count = 0;
};

class FirebaseClient {
 public:
  bool begin();
  bool ensureSignedIn(bool allowActiveAuth = true);
  bool pollCommands(FirebasePollResult& out);
  bool patchState(bool online, const String& relayState,
                  const String& fwVersion);
  bool deleteCommand(const String& commandId);
  bool writeAudit(const String& action, const String& channel,
                  const String& result, const String& reason,
                  const String& commandId, const String& actorUid);

  const String& lastError() const;
  bool shouldSkipCloudWrites() const;

 private:
  bool signInWithPassword();
  bool authBackoffActive(uint32_t nowMs) const;
  uint32_t secureSpacingRemainingMs(uint32_t nowMs) const;
  void recordAuthResult(bool success, const char* opName);
  void applyAuthBackoffMs(uint32_t backoffMs, const char* reason);
  void handleUnauthorizedResponse(int httpCode, const String& body,
                                  const char* scope);

  bool doJsonRequest(const String& method, const String& url,
                     const String& payload, String& body, int& httpCode,
                     bool secure = true,
                     const String& contentType = "application/json");

  String databaseUrl(const String& path) const;

  String idToken_;
  uint32_t nextAuthAttemptMs_ = 0;
  uint32_t authBackoffMs_ = poot::kFirebaseAuthRetryInitialMs;
  uint32_t lastAuthBackoffLogMs_ = 0;
  uint32_t nextSecureRequestAllowedMs_ = 0;
  uint32_t lastSecureRequestGapLogMs_ = 0;
  bool credentialsRejected_ = false;
  String lastError_;
};
