#pragma once

// Copy this file to secrets.h and replace every placeholder.

#define WIFI_STA_SSID "YOUR_HOME_WIFI_SSID"
#define WIFI_STA_PASSWORD "YOUR_HOME_WIFI_PASSWORD"

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

// Shared local fallback secret used for HMAC_SHA256(ts).
#define LOCAL_SHARED_SECRET "REPLACE_WITH_LONG_RANDOM_SECRET"
