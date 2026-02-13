#pragma once

#include <Arduino.h>

#include "storage.h"

struct LocalUnlockRequest {
  uint32_t ts = 0;
  String sig;
};

struct ValidationResult {
  bool ok = false;
  String reason;
};

namespace local_unlock {

void begin(Storage* storage, const String& sharedSecret, uint32_t timestampWindowSec,
           uint32_t replayRetentionSec, size_t replayCacheSize);

void setClockAnchor(uint32_t epochSec);
uint32_t approximateNow();

ValidationResult validate(const LocalUnlockRequest& request);

}  // namespace local_unlock
