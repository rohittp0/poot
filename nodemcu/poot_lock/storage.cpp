#include "storage.h"

#include <ArduinoJson.h>
#include <LittleFS.h>

#include "diagnostics.h"

namespace {
constexpr const char* kStateFile = "/state.json";

bool loadJsonDoc(DynamicJsonDocument& doc) {
  File file = LittleFS.open(kStateFile, "r");
  if (!file) {
    return false;
  }

  const auto err = deserializeJson(doc, file);
  file.close();
  return !err;
}

bool saveJsonDoc(const DynamicJsonDocument& doc) {
  File file = LittleFS.open(kStateFile, "w");
  if (!file) {
    return false;
  }

  const size_t written = serializeJson(doc, file);
  file.close();
  return written > 0;
}
}

bool Storage::begin() {
  if (!LittleFS.begin()) {
    poot_diag::logf("STORAGE", "LittleFS mount failed");
    return false;
  }
  poot_diag::logf("STORAGE", "LittleFS mounted");
  if (!LittleFS.exists(kStateFile)) {
    DynamicJsonDocument doc(256);
    doc["clock_anchor"] = 0;
    doc["cloud_cooldown_until"] = 0;
    doc.createNestedArray("replay");
    const bool saved = saveJsonDoc(doc);
    poot_diag::logf("STORAGE", "created %s: %s", kStateFile,
                    saved ? "ok" : "failed");
    return saved;
  }
  poot_diag::logf("STORAGE", "state file present: %s", kStateFile);
  return true;
}

bool Storage::loadClockAnchor(uint32_t& epochSec) {
  DynamicJsonDocument doc(1024);
  if (!loadJsonDoc(doc)) {
    poot_diag::logf("STORAGE", "loadClockAnchor failed to read %s", kStateFile);
    return false;
  }
  epochSec = doc["clock_anchor"] | 0;
  poot_diag::logf("STORAGE", "loaded clock anchor=%lu", epochSec);
  return true;
}

bool Storage::saveClockAnchor(uint32_t epochSec) {
  DynamicJsonDocument doc(2048);
  if (!loadJsonDoc(doc)) {
    doc["clock_anchor"] = 0;
    doc["cloud_cooldown_until"] = 0;
    doc.createNestedArray("replay");
  }

  doc["clock_anchor"] = epochSec;
  const bool saved = saveJsonDoc(doc);
  poot_diag::logf("STORAGE", "saved clock anchor=%lu (%s)", epochSec,
                  saved ? "ok" : "failed");
  return saved;
}

bool Storage::loadCloudCooldownUntil(uint32_t& epochSec) {
  DynamicJsonDocument doc(1024);
  if (!loadJsonDoc(doc)) {
    poot_diag::logf("STORAGE", "loadCloudCooldownUntil failed to read %s",
                    kStateFile);
    return false;
  }
  epochSec = doc["cloud_cooldown_until"] | 0;
  poot_diag::logf("STORAGE", "loaded cloud cooldown until=%lu", epochSec);
  return true;
}

bool Storage::saveCloudCooldownUntil(uint32_t epochSec) {
  DynamicJsonDocument doc(2048);
  if (!loadJsonDoc(doc)) {
    doc["clock_anchor"] = 0;
    doc.createNestedArray("replay");
  }

  doc["cloud_cooldown_until"] = epochSec;
  const bool saved = saveJsonDoc(doc);
  poot_diag::logf("STORAGE", "saved cloud cooldown until=%lu (%s)", epochSec,
                  saved ? "ok" : "failed");
  return saved;
}

bool Storage::loadReplayRecords(ReplayRecord* records, size_t& count,
                                size_t maxCount) {
  count = 0;
  DynamicJsonDocument doc(4096);
  if (!loadJsonDoc(doc)) {
    poot_diag::logf("STORAGE", "loadReplayRecords failed to read %s",
                    kStateFile);
    return false;
  }

  JsonArray replay = doc["replay"].as<JsonArray>();
  if (replay.isNull()) {
    return true;
  }

  for (JsonObject entry : replay) {
    if (count >= maxCount) {
      break;
    }
    records[count].ts = entry["ts"] | 0;
    const String sig = entry["sig"] | "";
    sig.toCharArray(records[count].sig, sizeof(records[count].sig));
    count++;
  }
  poot_diag::logf("STORAGE", "loaded replay records=%u", static_cast<unsigned>(count));
  return true;
}

bool Storage::saveReplayRecords(const ReplayRecord* records, size_t count) {
  DynamicJsonDocument doc(6144);
  if (!loadJsonDoc(doc)) {
    doc["clock_anchor"] = 0;
    doc["cloud_cooldown_until"] = 0;
  }

  JsonArray replay = doc["replay"].to<JsonArray>();
  replay.clear();

  for (size_t i = 0; i < count; i++) {
    JsonObject entry = replay.createNestedObject();
    entry["ts"] = records[i].ts;
    entry["sig"] = records[i].sig;
  }

  const bool saved = saveJsonDoc(doc);
  poot_diag::logf("STORAGE", "saved replay records=%u (%s)",
                  static_cast<unsigned>(count), saved ? "ok" : "failed");
  return saved;
}
