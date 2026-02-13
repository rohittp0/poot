#include "relay_control.h"

#include "diagnostics.h"

RelayController::RelayController(uint8_t pin, bool activeLow)
    : pin_(pin), activeLow_(activeLow) {}

void RelayController::begin() {
  pinMode(pin_, OUTPUT);
  writeRelay(false);
  poot_diag::logf("RELAY", "initialized pin=%u activeLow=%u", pin_,
                  activeLow_ ? 1 : 0);
}

void RelayController::loop() {
  const uint32_t now = millis();
  if (relayOn_ && now >= pulseEndMs_) {
    writeRelay(false);
    poot_diag::logf("RELAY", "pulse ended");
  }
}

bool RelayController::triggerPulse(uint32_t durationMs, uint32_t cooldownMs) {
  const uint32_t now = millis();
  if (now < cooldownUntilMs_) {
    poot_diag::logf("RELAY", "pulse denied: cooldown remaining=%lu ms",
                    cooldownUntilMs_ - now);
    return false;
  }

  writeRelay(true);
  pulseEndMs_ = now + durationMs;
  cooldownUntilMs_ = now + cooldownMs;
  poot_diag::logf("RELAY", "pulse started duration=%lu ms cooldown=%lu ms",
                  durationMs, cooldownMs);
  return true;
}

bool RelayController::isRelayOn() const { return relayOn_; }

bool RelayController::isCoolingDown() const {
  return millis() < cooldownUntilMs_;
}

void RelayController::writeRelay(bool on) {
  relayOn_ = on;
  const uint8_t level = activeLow_ ? (on ? LOW : HIGH) : (on ? HIGH : LOW);
  digitalWrite(pin_, level);
}
