# Poot NodeMCU Firmware

Arduino IDE firmware for ESP8266 NodeMCU smart lock control.

## Files

- `poot_lock.ino`: main sketch
- `config.h`: runtime constants
- `secrets.example.h`: credential template
- `secrets.h`: local credentials (fill before flashing)
- `firebase_client.*`: Firebase Auth + Realtime DB REST
- `relay_control.*`: relay pulse + cooldown
- `local_unlock.*`: local HMAC/timestamp/replay validation
- `storage.*`: LittleFS persistence for clock anchor and replay cache
- `WIRING.md`: full wiring diagram and pin mapping (Mermaid + SVG/PNG)

## Required Arduino libraries

Install from Arduino Library Manager:
- `ArduinoJson`

Use ESP8266 board package (contains):
- `ESP8266WiFi`
- `ESP8266WebServer`
- `ESP8266HTTPClient`
- `LittleFS`
- `BearSSL`

## Build target

- Board: `NodeMCU 1.0 (ESP-12E Module)`
- CPU Frequency: `80 MHz` (default is fine)
- Flash Size: `4MB (FS:2MB OTA:~1019KB)` or similar with LittleFS enabled

## Credential setup

Use the root initializer script (recommended):

```bash
cd /Users/rohittp/Data/Other/poot
./init.sh
```

What `./init.sh` does:
- Reads Firebase app values from `app/lib/firebase_options.dart` (optionally refreshes it via FlutterFire).
- Uses Firebase CLI (if available) to detect Realtime Database URL.
- Generates `secrets.h` for NodeMCU.
- Generates Flutter fallback defaults in `app/lib/src/config/local_fallback_defaults.dart`.
- Auto-generates and prints AP password + shared HMAC secret.
- Auto-generates Firebase device password and can create Firebase Auth device user.

Manual alternative:

```bash
cp secrets.example.h secrets.h
```

Set:
- Home Wi-Fi STA credentials
- AP SSID/password (always-on fallback AP)
- Firebase API key, DB URL, device account credentials
- `LOCK_ID`
- `LOCAL_SHARED_SECRET`

## Local unlock contract

Endpoint on ESP AP:
- `GET /api/local-time`
- `POST /api/local-unlock`

`GET /api/local-time` response:

```json
{
  "ok": true,
  "ts": 1739401200,
  "windowSec": 300,
  "source": "anchor"
}
```

JSON body:

```json
{
  "ts": 1739401200,
  "sig": "hex_hmac_sha256(sharedSecret, ts)"
}
```

Validation:
- timestamp window (`+/-300s`)
- replay protection using recent signature cache

## Device account authorization

Cloud device access is granted via:

- `/locks/{lockId}/deviceAccount`
    - `uid`
    - `email`
    - `enabled`
    - `updatedAt`

For rollout safety, rules can temporarily allow the legacy hardcoded email path.
Use the app admin screen (or `./admin.sh --device-email ...`) to keep device
identity aligned with firmware credentials.

## Relay behavior

- Boot state: locked
- Unlock mode: pulse (default `900ms`)
- Cooldown: `5000ms`

## Inside button unlock

- Button pin: `D5` (`kExitButtonPin` in `config.h`)
- Wiring: one side of push button to `D5`, other side to `GND`
- Logic: `INPUT_PULLUP`, press drives pin LOW
- Action: debounced press triggers same unlock pulse as cloud/local unlock

## Wiring diagram

- See `WIRING.md` for the complete wiring package:
    - Mermaid source: `assets/wiring_diagram.mmd`
    - Electronic PCB/terminal source: `assets/electronic_pcb_terminal_diagram.mmd`
    - Photo overlay source: `assets/photo_terminal_overlay_diagram.svg`
    - Rendered assets:
        - `assets/wiring_diagram.svg` and `assets/wiring_diagram.png`
        - `assets/electronic_pcb_terminal_diagram.svg` and `assets/electronic_pcb_terminal_diagram.png`
        - `assets/photo_terminal_overlay_diagram.png`

## Onboard LED status

- LED off: lock is currently unlocked (during relay pulse)
- LED solid on: Wi-Fi connected
- LED fast blink: currently connecting to Wi-Fi
- LED slow blink: Wi-Fi disconnected/lost/scanning

## Serial diagnostics

- Open Serial Monitor at `115200` baud.
- Firmware prints tagged diagnostics for boot, Wi-Fi/AP, HTTP local unlock,
  relay/button actions, local validation failures, Firebase auth/polling,
  heartbeat, audit writes, and clock sync.
- Firmware now serializes auth attempts, enforces secure-request spacing, and
  persists cloud cooldown to avoid auth crash loops during outages/rate limits.
- Toggle logs via `kEnableSerialDiagnostics` in `config.h`.

