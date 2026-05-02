#pragma once

#include <Arduino.h>

namespace poot {

static constexpr uint32_t kSerialBaud = 115200;
static constexpr bool kEnableSerialDiagnostics = true;

static constexpr uint8_t kRelayPin = D1;
static constexpr bool kRelayActiveLow = true;

// NodeMCU onboard LED is active-low on most ESP8266 boards.
static constexpr uint8_t kStatusLedPin = LED_BUILTIN;
static constexpr bool kStatusLedActiveLow = true;
static constexpr uint32_t kStatusBlinkSlowMs = 700;
static constexpr uint32_t kStatusBlinkFastMs = 180;
static constexpr uint32_t kWiFiConnectingWindowMs = 8000;

static constexpr uint32_t kUnlockPulseMs = 5000;
static constexpr uint32_t kUnlockCooldownMs = 5000;
static constexpr uint32_t kWiFiReconnectMs = 12000;
static constexpr uint32_t kNetworkEnsureMs = 1000;
static constexpr uint32_t kWiFiStatusLogIntervalMs = 3000;
static constexpr uint32_t kHttpServerReassertMs = 15000;

static constexpr uint16_t kLocalHttpPort = 80;
static constexpr uint8_t  kApMaxConnections = 4;          // 0-8
static constexpr uint16_t kOtaPort = 8266;                // ArduinoOTA default
static constexpr const char* kMdnsHostname = "poot";

// Auto-reboot every hour to reset soft state. The reboot is unconditional;
// in-flight AP unlocks are interrupted but the phone simply retries.
static constexpr uint32_t kAutoRebootIntervalMs = 60UL * 60UL * 1000UL;

static constexpr const char* kFirmwareVersion = "poot-esp8266-2.1.0";

}  // namespace poot
