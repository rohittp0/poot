#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>

struct ReplayRecord {
  uint32_t ts = 0;
  char sig[65] = {0};
};

class Storage {
 public:
  bool begin();

  bool loadClockAnchor(uint32_t& epochSec);
  bool saveClockAnchor(uint32_t epochSec);
  bool loadCloudCooldownUntil(uint32_t& epochSec);
  bool saveCloudCooldownUntil(uint32_t epochSec);

  bool loadReplayRecords(ReplayRecord* records, size_t& count, size_t maxCount);
  bool saveReplayRecords(const ReplayRecord* records, size_t count);
};
