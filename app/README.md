# Poot App (Flutter)

Flutter mobile app for Poot lock control.

## Features

- Firebase Authentication (Google + Apple)
- Session restore on launch
- Biometric authorization on app open
- Cloud-first unlock command flow with Firebase Realtime Database
- Automatic fallback to ESP8266 hotspot local unlock
- Admin cloud user access management
- Local fallback settings (SSID, password, shared secret)

## Environment and setup

1. Generate/update FlutterFire config:

```bash
cd app
flutterfire configure --project=<YOUR_FIREBASE_PROJECT_ID> --platforms=android,ios
```

2. Run the app:

```bash
cd app
flutter pub get
flutter run
```

3. (Recommended) run the root initializer once to auto-fill local fallback defaults
   used by the app (`SSID`, `AP password`, shared HMAC secret):

```bash
cd /Users/rohittp/Data/Other/poot
./init.sh
```

`init.sh` also generates NodeMCU `secrets.h` and can create the Firebase Auth
device user. It also creates/reuses `android/poot-upload-keystore.jks`,
writes `android/key.properties`, and configures the app to sign Android debug
and release builds with that key.

## Local fallback auth model

Local fallback payload contains only:
- `ts`
- `sig = HMAC_SHA256(sharedSecret, ts)`

No UID is sent in local requests.
