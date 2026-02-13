# Poot

Poot is a Firebase-backed smart lock project with:
- `app/`: Flutter app (Android + iOS)
- `nodemcu/`: ESP8266 NodeMCU firmware (Arduino IDE)

## Project layout

- `app/`
  - Flutter app branded as **Poot**
  - Google + Apple sign-in
  - App-open biometric unlock flow
  - Cloud-first unlock with automatic local AP fallback
- `nodemcu/poot_lock/`
  - Arduino sketch for NodeMCU 1.0 (ESP-12E)
  - AP+STA mode
  - Firebase command polling + heartbeat + audit writes
  - Local unlock API with shared-secret HMAC validation
- `firebase/database.rules.json`
  - Realtime Database rules template

## Cloud contract (Realtime Database)

- `/locks/{lockId}/commands/{commandId}`
- `/locks/{lockId}/state`
- `/locks/{lockId}/users/{uid}`
- `/locks/{lockId}/identity/{uid}`
- `/locks/{lockId}/deviceAccount`
- `/locks/{lockId}/audit/{eventId}`

## Local unlock API

`POST http://192.168.4.1/api/local-unlock`

Body:

```json
{
  "ts": 1739401200,
  "sig": "hex_hmac_sha256(sharedSecret, ts)"
}
```

## Setup

### 1) Firebase

1. Create a Firebase project.
2. Enable Authentication providers:
   - Google
   - Apple (for public iOS release)
3. Create Realtime Database.
4. Apply rules from `firebase/database.rules.json`.
5. Create a dedicated device auth account (email/password), e.g. `lock-device@example.com`.
6. Grant admin access for your user (recommended script):

```bash
cd /Users/rohittp/Data/Other/poot
./admin.sh your-email@example.com
```

This grants `/users/{uid}` and seeds `/identity/{uid}` for email-based admin UI.

7. Seed device account (optional script flow, or do it from app admin UI):

```bash
cd /Users/rohittp/Data/Other/poot
./admin.sh --device-email lock-device@example.com
```

This writes `/locks/{lockId}/deviceAccount` with `uid`, `email`, `enabled`, and `updatedAt`.

8. If doing it manually, add your UID under `/locks/front-door/users/{uid}` with:
   - `role: "admin"`
   - `enabled: true`

### 2) Flutter app

1. Generate FlutterFire config:

```bash
cd app
flutterfire configure --project=<YOUR_FIREBASE_PROJECT_ID> --platforms=android,ios
```

2. Run app:

```bash
cd app
flutter pub get
flutter run
```

### 3) NodeMCU firmware

1. Run bootstrap initializer (recommended first). This will:
   - optionally refresh `app/lib/firebase_options.dart` via FlutterFire
   - generate/reuse Android signing keystore in `app/android/`
   - register Android SHA1/SHA256 in Firebase (via Firebase CLI, when available)
   - refresh `app/android/app/google-services.json` from Firebase
   - try to detect Realtime Database URL via Firebase CLI
   - generate `nodemcu/poot_lock/secrets.h`
   - generate Flutter local fallback defaults in `app/lib/src/config/local_fallback_defaults.dart`
   - auto-generate and print fallback AP password + shared HMAC secret
   - auto-generate Firebase device password and optionally create device user in Firebase Auth

```bash
cd /Users/rohittp/Data/Other/poot
./init.sh
```

2. Open `nodemcu/poot_lock/poot_lock.ino` in Arduino IDE.
3. Install ESP8266 board package and required libraries (see firmware README).
4. Select board: `NodeMCU 1.0 (ESP-12E Module)`.
5. Build and flash.

### 4) Run Flutter app

```bash
cd /Users/rohittp/Data/Other/poot/app
flutter pub get
flutter run
```

## Notes

- Local fallback auth is intentionally secret-based only: anyone with the shared secret can unlock locally.
- No local cached allowlist and no UID in local payload.
- Keep `shared_hmac_secret` rotated periodically.
- If cloud logs show repeated `401 unauthorized`, verify `/locks/{lockId}/deviceAccount` matches the firmware device user email + UID.
