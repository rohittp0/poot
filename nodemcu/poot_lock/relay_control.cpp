#include "relay_control.h"

#include "diagnostics.h"

namespace {

bool timeReached(uint32_t now, uint32_t target) {
  return static_cast<int32_t>(now - target) >= 0;
}

}  // namespace

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
  if (relayOn_ && timeReached(now, pulseEndMs_)) {
    writeRelay(false);
    poot_diag::logf("RELAY", "pulse ended");
  }
}

bool RelayController::triggerPulse(uint32_t durationMs, uint32_t cooldownMs) {
  const uint32_t now = millis();
  if (relayOn_) {
    pulseEndMs_ = now + durationMs;
    cooldownUntilMs_ = pulseEndMs_ + cooldownMs;
    poot_diag::logf("RELAY", "pulse refreshed duration=%lu ms cooldown=%lu ms",
                    durationMs, cooldownMs);
    return true;
  }

  const bool restartingDuringCooldown =
      cooldownUntilMs_ != 0 && !timeReached(now, cooldownUntilMs_);
  writeRelay(true);
  pulseEndMs_ = now + durationMs;
  cooldownUntilMs_ = pulseEndMs_ + cooldownMs;
  poot_diag::logf("RELAY", "%s duration=%lu ms cooldown=%lu ms",
                  restartingDuringCooldown ? "pulse restarted during cooldown"
                                           : "pulse started",
                  durationMs, cooldownMs);
  return true;
}

bool RelayController::isRelayOn() const { return relayOn_; }

bool RelayController::isCoolingDown() const {
  return cooldownUntilMs_ != 0 && !timeReached(millis(), cooldownUntilMs_);
}

void RelayController::writeRelay(bool on) {
  relayOn_ = on;
  const uint8_t level = activeLow_ ? (on ? LOW : HIGH) : (on ? HIGH : LOW);
  digitalWrite(pin_, level);
}
