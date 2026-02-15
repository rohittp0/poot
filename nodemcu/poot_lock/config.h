#pragma once

#include <Arduino.h>

namespace poot {

static constexpr uint32_t kSerialBaud = 115200;
static constexpr bool kEnableSerialDiagnostics = true;

static constexpr uint8_t kRelayPin = D1;
static constexpr bool kRelayActiveLow = true;

// Inside unlock button: wire one leg to this pin and the other to GND.
// INPUT_PULLUP is used, so pressed state is LOW.
static constexpr uint8_t kExitButtonPin = D5;
static constexpr bool kExitButtonActiveLow = true;
static constexpr uint32_t kExitButtonDebounceMs = 40;

// NodeMCU onboard LED is active-low on most ESP8266 boards.
static constexpr uint8_t kStatusLedPin = LED_BUILTIN;
static constexpr bool kStatusLedActiveLow = true;
static constexpr uint32_t kStatusBlinkSlowMs = 700;
static constexpr uint32_t kStatusBlinkFastMs = 180;
static constexpr uint32_t kWiFiConnectingWindowMs = 8000;

static constexpr uint32_t kUnlockPulseMs = 5000;
static constexpr uint32_t kUnlockCooldownMs = 5000;
static constexpr uint32_t kCloudPollMs = 2500;
static constexpr uint32_t kHeartbeatMs = 30000;
static constexpr uint32_t kWiFiReconnectMs = 10000;
static constexpr uint32_t kWiFiStatusLogIntervalMs = 30000;
static constexpr uint32_t kCloudStartDelayAfterWiFiMs = 7000;

static constexpr uint32_t kTimestampWindowSec = 300;
static constexpr uint32_t kReplayRetentionSec = 600;
static constexpr uint8_t kReplayCacheSize = 24;

static constexpr uint16_t kLocalHttpPort = 80;
static constexpr uint8_t kApChannel = 6;
static constexpr uint8_t kApMaxConnections = 4;

static constexpr const char* kFirmwareVersion = "poot-esp8266-1.0.8";

static constexpr uint32_t kFirebaseTokenRefreshSkewSec = 120;
static constexpr uint8_t kCommandFetchLimit = 6;
static constexpr uint32_t kFirebaseHttpTimeoutMs = 2000;
static constexpr uint32_t kFirebaseSocketTimeoutMs = 1500;
static constexpr uint32_t kFirebaseAuthRetryInitialMs = 8000;
static constexpr uint32_t kFirebaseAuthRetryMaxMs = 120000;
static constexpr uint32_t kFirebaseAuthBackoffLogMs = 5000;
static constexpr uint32_t kFirebaseRateLimitBackoffMs = 300000;
static constexpr uint32_t kFirebaseUnauthorizedBackoffMs = 300000;
static constexpr uint32_t kFirebaseSecureRequestGapMs = 2500;
static constexpr uint32_t kFirebaseLowHeapBackoffMs = 60000;
static constexpr uint32_t kFirebaseMinFreeHeapBytes = 20000;
static constexpr uint32_t kFirebaseMinMaxBlockBytes = 9000;
static constexpr uint16_t kFirebaseTlsRxBufferBytes = 1024;
static constexpr uint16_t kFirebaseTlsTxBufferBytes = 1024;

}  // namespace poot
