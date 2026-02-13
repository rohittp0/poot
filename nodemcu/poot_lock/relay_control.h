#pragma once

#include <Arduino.h>

class RelayController {
 public:
  RelayController(uint8_t pin, bool activeLow);

  void begin();
  void loop();

  bool triggerPulse(uint32_t durationMs, uint32_t cooldownMs);
  bool isRelayOn() const;
  bool isCoolingDown() const;

 private:
  void writeRelay(bool on);

  uint8_t pin_;
  bool activeLow_;

  bool relayOn_ = false;
  uint32_t pulseEndMs_ = 0;
  uint32_t cooldownUntilMs_ = 0;
};
