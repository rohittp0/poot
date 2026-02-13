#include "local_unlock.h"

#include <bearssl/bearssl.h>

#include "diagnostics.h"

namespace {
Storage* gStorage = nullptr;
String gSharedSecret;

uint32_t gClockAnchorEpoch = 0;
uint32_t gClockAnchorMillis = 0;

uint32_t gTimestampWindowSec = 120;
uint32_t gReplayRetentionSec = 600;
size_t gReplayCacheSize = 24;

ReplayRecord gReplay[32];
size_t gReplayCount = 0;

String toHex(const uint8_t* bytes, size_t len) {
  static const char* kHex = "0123456789abcdef";
  String out;
  out.reserve(len * 2);
  for (size_t i = 0; i < len; i++) {
    out += kHex[(bytes[i] >> 4) & 0x0F];
    out += kHex[bytes[i] & 0x0F];
  }
  return out;
}

String hmacSha256Hex(const String& key, const String& message) {
  uint8_t keyBlock[64] = {0};
  if (key.length() > 64) {
    br_sha256_context keyHash;
    br_sha256_init(&keyHash);
    br_sha256_update(&keyHash, key.c_str(), key.length());
    br_sha256_out(&keyHash, keyBlock);
  } else {
    memcpy(keyBlock, key.c_str(), key.length());
  }

  uint8_t innerPad[64];
  uint8_t outerPad[64];

  for (size_t i = 0; i < 64; i++) {
    innerPad[i] = keyBlock[i] ^ 0x36;
    outerPad[i] = keyBlock[i] ^ 0x5C;
  }

  uint8_t innerHash[32];
  br_sha256_context inner;
  br_sha256_init(&inner);
  br_sha256_update(&inner, innerPad, sizeof(innerPad));
  br_sha256_update(&inner, message.c_str(), message.length());
  br_sha256_out(&inner, innerHash);

  uint8_t out[32];
  br_sha256_context outer;
  br_sha256_init(&outer);
  br_sha256_update(&outer, outerPad, sizeof(outerPad));
  br_sha256_update(&outer, innerHash, sizeof(innerHash));
  br_sha256_out(&outer, out);

  return toHex(out, sizeof(out));
}

bool constantTimeEquals(const String& a, const String& b) {
  if (a.length() != b.length()) {
    return false;
  }

  uint8_t diff = 0;
  for (size_t i = 0; i < a.length(); i++) {
    diff |= static_cast<uint8_t>(a[i] ^ b[i]);
  }
  return diff == 0;
}

void compactReplay(uint32_t nowSec) {
  size_t write = 0;
  for (size_t i = 0; i < gReplayCount; i++) {
    if (nowSec - gReplay[i].ts <= gReplayRetentionSec) {
      if (write != i) {
        gReplay[write] = gReplay[i];
      }
      write++;
    }
  }
  gReplayCount = write;
}

bool isReplay(const String& sig) {
  for (size_t i = 0; i < gReplayCount; i++) {
    if (sig.equals(gReplay[i].sig)) {
      return true;
    }
  }
  return false;
}

void remember(const String& sig, uint32_t ts) {
  if (gReplayCacheSize > 32) {
    gReplayCacheSize = 32;
  }

  if (gReplayCount < gReplayCacheSize) {
    gReplay[gReplayCount].ts = ts;
    sig.toCharArray(gReplay[gReplayCount].sig, sizeof(gReplay[gReplayCount].sig));
    gReplayCount++;
  } else {
    for (size_t i = 1; i < gReplayCount; i++) {
      gReplay[i - 1] = gReplay[i];
    }
    gReplay[gReplayCount - 1].ts = ts;
    sig.toCharArray(gReplay[gReplayCount - 1].sig,
                    sizeof(gReplay[gReplayCount - 1].sig));
  }

  if (gStorage != nullptr) {
    gStorage->saveReplayRecords(gReplay, gReplayCount);
  }
}

}  // namespace

namespace local_unlock {

void begin(Storage* storage, const String& sharedSecret, uint32_t timestampWindowSec,
           uint32_t replayRetentionSec, size_t replayCacheSize) {
  gStorage = storage;
  gSharedSecret = sharedSecret;
  gTimestampWindowSec = timestampWindowSec;
  gReplayRetentionSec = replayRetentionSec;
  gReplayCacheSize = replayCacheSize;

  if (gStorage != nullptr) {
    gStorage->loadClockAnchor(gClockAnchorEpoch);

    size_t count = 0;
    if (gStorage->loadReplayRecords(gReplay, count, 32)) {
      gReplayCount = count;
    }
  }

  gClockAnchorMillis = millis();
  poot_diag::logf("LOCAL", "init clockAnchor=%lu replayCount=%u window=%lu s retention=%lu s cache=%u",
                  gClockAnchorEpoch, static_cast<unsigned>(gReplayCount),
                  gTimestampWindowSec, gReplayRetentionSec,
                  static_cast<unsigned>(gReplayCacheSize));
}

void setClockAnchor(uint32_t epochSec) {
  if (epochSec == 0) {
    return;
  }

  gClockAnchorEpoch = epochSec;
  gClockAnchorMillis = millis();
  if (gStorage != nullptr) {
    gStorage->saveClockAnchor(epochSec);
  }
  poot_diag::logf("LOCAL", "clock anchor set=%lu", epochSec);
}

uint32_t approximateNow() {
  if (gClockAnchorEpoch == 0) {
    return 0;
  }

  const uint32_t elapsed = (millis() - gClockAnchorMillis) / 1000;
  return gClockAnchorEpoch + elapsed;
}

ValidationResult validate(const LocalUnlockRequest& request) {
  ValidationResult result;

  if (request.ts == 0 || request.sig.length() < 32) {
    result.reason = "bad_request";
    poot_diag::logf("LOCAL", "validate denied: bad_request ts=%lu sigLen=%u",
                    request.ts, request.sig.length());
    return result;
  }

  const String expected = hmacSha256Hex(gSharedSecret, String(request.ts));
  if (!constantTimeEquals(expected, request.sig)) {
    result.reason = "signature_mismatch";
    poot_diag::logf("LOCAL", "validate denied: signature_mismatch ts=%lu",
                    request.ts);
    return result;
  }

  uint32_t nowSec = approximateNow();
  if (nowSec == 0) {
    // Bootstrap clock in offline-first situations from the first valid request.
    setClockAnchor(request.ts);
    nowSec = request.ts;
    poot_diag::logf("LOCAL", "bootstrap anchor from request ts=%lu", request.ts);
  }

  const int32_t delta = static_cast<int32_t>(request.ts) -
                        static_cast<int32_t>(nowSec);
  if (delta < -static_cast<int32_t>(gTimestampWindowSec) ||
      delta > static_cast<int32_t>(gTimestampWindowSec)) {
    result.reason = "timestamp_out_of_window";
    poot_diag::logf("LOCAL", "validate denied: timestamp_out_of_window ts=%lu now=%lu delta=%ld",
                    request.ts, nowSec, static_cast<long>(delta));
    return result;
  }

  compactReplay(nowSec);
  if (isReplay(request.sig)) {
    result.reason = "replay_detected";
    poot_diag::logf("LOCAL", "validate denied: replay_detected ts=%lu",
                    request.ts);
    return result;
  }

  remember(request.sig, request.ts);

  result.ok = true;
  result.reason = "ok";
  poot_diag::logf("LOCAL", "validate success ts=%lu now=%lu", request.ts, nowSec);
  return result;
}

}  // namespace local_unlock
