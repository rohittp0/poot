#pragma once

// Copy this file to secrets.h and replace every placeholder.

#define WIFI_STA_SSID "YOUR_HOME_WIFI_SSID"
#define WIFI_STA_PASSWORD "YOUR_HOME_WIFI_PASSWORD"
#define WIFI_STA_IP IPAddress(192, 168, 1, 192)
#define WIFI_STA_GATEWAY IPAddress(192, 168, 1, 1)
#define WIFI_STA_SUBNET IPAddress(255, 255, 255, 0)
#define WIFI_STA_DNS1 IPAddress(192, 168, 1, 1)
#define WIFI_STA_DNS2 IPAddress(8, 8, 8, 8)

#define LOCK_ID "front-door"

// Shared key sent in ?key= query parameter to /api/local-unlock and /api/health.
#define LOCAL_SHARED_KEY "REPLACE_WITH_LONG_RANDOM_KEY"

// Always-on fallback AP (created by the lock). The phone joins this when home
// Wi-Fi is unreachable and unlocks at http://192.168.4.1/api/local-unlock.
#define WIFI_AP_SSID "poot-fallback"
#define WIFI_AP_PASSWORD "REPLACE_AT_LEAST_8_CHARS"
#define WIFI_AP_CHANNEL 1            // 1-13; in AP_STA mode the chip follows the STA channel anyway

// Wireless OTA (only reachable on STA).
#define OTA_PASSWORD "REPLACE_WITH_OTA_PASSWORD"
