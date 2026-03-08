#pragma once

// Copy this file to secrets.h and replace every placeholder.

#define WIFI_STA_SSID "YOUR_HOME_WIFI_SSID"
#define WIFI_STA_PASSWORD "YOUR_HOME_WIFI_PASSWORD"
#define WIFI_STA_IP IPAddress(192, 168, 1, 192)
#define WIFI_STA_GATEWAY IPAddress(192, 168, 1, 1)
#define WIFI_STA_SUBNET IPAddress(255, 255, 255, 0)
#define WIFI_STA_DNS1 IPAddress(192, 168, 1, 1)
#define WIFI_STA_DNS2 IPAddress(8, 8, 8, 8)

#define AP_SSID "Poot-Lock"
#define AP_PASSWORD "CHANGE_ME_MIN_8_CHARS"

// Realtime Database base URL, without trailing slash.
// Example: https://your-project-default-rtdb.firebaseio.com
#define FIREBASE_DB_URL "https://YOUR_PROJECT-default-rtdb.firebaseio.com"
#define FIREBASE_API_KEY "YOUR_FIREBASE_WEB_API_KEY"

// Dedicated device Firebase Auth account.
#define FIREBASE_DEVICE_EMAIL "device-lock@example.com"
#define FIREBASE_DEVICE_PASSWORD "DEVICE_ACCOUNT_PASSWORD"

#define LOCK_ID "front-door"

// Shared local fallback key sent directly to /api/local-unlock.
#define LOCAL_SHARED_KEY "REPLACE_WITH_LONG_RANDOM_KEY"
