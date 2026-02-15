#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/app"
ANDROID_DIR="$APP_DIR/android"
FIREBASE_OPTIONS_FILE="$APP_DIR/lib/firebase_options.dart"
SECRETS_FILE="$ROOT_DIR/nodemcu/poot_lock/secrets.h"
FLUTTER_LOCAL_DEFAULTS_FILE="$APP_DIR/lib/src/config/local_fallback_defaults.dart"
NODEMCU_CONFIG_FILE="$ROOT_DIR/nodemcu/poot_lock/config.h"
ANDROID_KEYSTORE_FILE="$ANDROID_DIR/poot-upload-keystore.jks"
ANDROID_KEY_PROPERTIES_FILE="$ANDROID_DIR/key.properties"

resolve_flutterfire_bin() {
  if command -v flutterfire >/dev/null 2>&1; then
    command -v flutterfire
    return
  fi

  if [[ -x "$HOME/.pub-cache/bin/flutterfire" ]]; then
    echo "$HOME/.pub-cache/bin/flutterfire"
    return
  fi

  echo ""
}

resolve_firebase_bin() {
  if command -v firebase >/dev/null 2>&1; then
    command -v firebase
    return
  fi

  echo ""
}

resolve_jq_bin() {
  if command -v jq >/dev/null 2>&1; then
    command -v jq
    return
  fi

  echo ""
}

resolve_keytool_bin() {
  if command -v keytool >/dev/null 2>&1; then
    command -v keytool
    return
  fi

  echo ""
}

prompt() {
  local message="$1"
  local default_value="${2:-}"
  local answer

  if [[ -n "$default_value" ]]; then
    read -r -p "$message [$default_value]: " answer
    if [[ -z "$answer" ]]; then
      answer="$default_value"
    fi
  else
    read -r -p "$message: " answer
  fi

  echo "$answer"
}

trim() {
  local value="$1"
  # shellcheck disable=SC2001
  value="$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  echo "$value"
}

read_properties_value() {
  local file_path="$1"
  local key="$2"
  local value
  value="$(sed -n "s/^${key}=//p" "$file_path" | head -n 1)"
  value="${value//$'\r'/}"
  echo "$value"
}

prompt_secret() {
  local message="$1"
  local answer
  read -r -s -p "$message: " answer
  printf '\n' >&2
  answer="${answer//$'\r'/}"
  answer="${answer//$'\n'/}"
  echo "$answer"
}

extract_android_option() {
  local key="$1"
  sed -n "/static const FirebaseOptions android = FirebaseOptions(/,/^  );/p" "$FIREBASE_OPTIONS_FILE" \
    | sed -n "s/.*$key: '\\([^']*\\)'.*/\\1/p" \
    | head -n 1
}

detect_db_url_with_firebase_cli() {
  local firebase_bin="$1"
  local project_id="$2"

  if [[ -z "$firebase_bin" ]]; then
    echo ""
    return
  fi

  local output
  if ! output="$("$firebase_bin" database:instances:list --project "$project_id" --json 2>/dev/null)"; then
    echo ""
    return
  fi

  local url
  url="$(printf '%s' "$output" | grep -Eo 'https://[^" ]*(firebaseio\.com|firebasedatabase\.app)' | head -n 1 || true)"
  echo "$url"
}

detect_db_instance_from_url() {
  local url="$1"
  local host
  host="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+).*$#\1#')"
  if [[ "$host" =~ ^([^./]+)\. ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  echo ""
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi

  if command -v hexdump >/dev/null 2>&1; then
    hexdump -n 32 -v -e '/1 "%02x"' /dev/urandom
    echo
    return
  fi

  # Last-resort fallback.
  date +%s%N | shasum | awk '{print $1}'
}

generate_ap_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
    return
  fi

  if command -v hexdump >/dev/null 2>&1; then
    hexdump -n 8 -v -e '/1 "%02x"' /dev/urandom
    echo
    return
  fi

  echo "Poot$(date +%s)"
}

generate_device_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 12
    return
  fi

  if command -v hexdump >/dev/null 2>&1; then
    hexdump -n 12 -v -e '/1 "%02x"' /dev/urandom
    echo
    return
  fi

  echo "Dev$(date +%s)"
}

generate_signing_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
    return
  fi

  if command -v hexdump >/dev/null 2>&1; then
    hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom
    echo
    return
  fi

  date +%s%N | shasum | awk '{print substr($1,1,32)}'
}

try_create_device_user() {
  local api_key="$1"
  local email="$2"
  local password="$3"

  if ! command -v curl >/dev/null 2>&1; then
    echo "missing_curl"
    return 0
  fi

  local endpoint="https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${api_key}"
  local payload
  payload="$(printf '{"email":"%s","password":"%s","returnSecureToken":true}' "$email" "$password")"

  local response
  if ! response="$(curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$endpoint" 2>/dev/null)"; then
    echo "request_failed"
    return 0
  fi

  if printf '%s' "$response" | grep -q '"localId"'; then
    echo "created"
    return 0
  fi

  if printf '%s' "$response" | grep -q 'EMAIL_EXISTS'; then
    echo "exists"
    return 0
  fi

  local error_message
  error_message="$(printf '%s' "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ -n "$error_message" ]]; then
    echo "error:$error_message"
    return 0
  fi

  local compact_response
  compact_response="$(printf '%s' "$response" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  echo "error_response:$compact_response"
}

resolve_uid_by_email() {
  local firebase_bin="$1"
  local jq_bin="$2"
  local project_id="$3"
  local email="$4"

  if [[ -z "$firebase_bin" || -z "$jq_bin" ]]; then
    echo ""
    return
  fi

  local tmp_users_file
  tmp_users_file="$(mktemp)"
  if ! "$firebase_bin" auth:export "$tmp_users_file" --project "$project_id" --format=json >/dev/null 2>&1; then
    rm -f "$tmp_users_file"
    echo ""
    return
  fi

  local uid
  uid="$("$jq_bin" -r --arg email "$email" '
    .users[]? | select((.email // "" | ascii_downcase) == ($email | ascii_downcase)) | .localId
  ' "$tmp_users_file" | head -n 1)"
  rm -f "$tmp_users_file"

  if [[ -z "$uid" || "$uid" == "null" ]]; then
    echo ""
    return
  fi
  echo "$uid"
}

seed_device_account() {
  local firebase_bin="$1"
  local jq_bin="$2"
  local project_id="$3"
  local lock_id="$4"
  local instance="$5"
  local uid="$6"
  local email="$7"

  if [[ -z "$firebase_bin" ]]; then
    echo "skipped_no_cli"
    return
  fi
  if [[ -z "$jq_bin" ]]; then
    echo "skipped_no_jq"
    return
  fi
  if [[ -z "$uid" ]]; then
    echo "uid_not_found"
    return
  fi

  local updated_at
  updated_at="$(date +%s)"
  local payload
  payload="$("$jq_bin" -cn --arg uid "$uid" --arg email "$email" --argjson enabled true --argjson updatedAt "$updated_at" '
    {uid: $uid, email: ($email | ascii_downcase), enabled: $enabled, updatedAt: $updatedAt}
  ')"

  local -a cmd
  local output
  cmd=("$firebase_bin" "database:update" "/locks/$lock_id/deviceAccount" "--project" "$project_id" "--data" "$payload" "--force")
  if [[ -n "$instance" ]]; then
    cmd+=("--instance" "$instance")
  fi

  if output="$("${cmd[@]}" 2>&1)"; then
    echo "updated"
    return
  fi

  local compact_output
  compact_output="$(printf '%s' "$output" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  echo "error:$compact_output"
}

create_android_signing_keystore() {
  local keytool_bin="$1"
  local keystore_file="$2"
  local store_password="$3"
  local key_alias="$4"
  local key_password="$5"
  local dname="$6"

  "$keytool_bin" -genkeypair -v \
    -keystore "$keystore_file" \
    -storetype JKS \
    -storepass "$store_password" \
    -keypass "$key_password" \
    -alias "$key_alias" \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname "$dname" >/dev/null 2>&1
}

extract_keystore_fingerprint() {
  local keytool_bin="$1"
  local keystore_file="$2"
  local key_alias="$3"
  local store_password="$4"
  local key_password="$5"
  local kind="$6"
  local fingerprint

  fingerprint="$("$keytool_bin" -list -v \
    -keystore "$keystore_file" \
    -alias "$key_alias" \
    -storepass "$store_password" \
    -keypass "$key_password" 2>/dev/null \
    | sed -n "s/^[[:space:]]*${kind}:[[:space:]]*//p" \
    | head -n 1)"
  echo "$fingerprint"
}

register_android_sha_with_firebase() {
  local firebase_bin="$1"
  local project_id="$2"
  local android_app_id="$3"
  local sha_value="$4"
  local output

  if [[ -z "$firebase_bin" ]]; then
    echo "skipped_no_cli"
    return
  fi

  if [[ -z "$android_app_id" || -z "$sha_value" ]]; then
    echo "skipped_missing_value"
    return
  fi

  if output="$("$firebase_bin" apps:android:sha:create "$android_app_id" "$sha_value" --project "$project_id" 2>&1)"; then
    echo "created"
    return
  fi

  if printf '%s' "$output" | grep -qiE 'ALREADY_EXISTS|already exists'; then
    echo "exists"
    return
  fi

  local compact_output
  compact_output="$(printf '%s' "$output" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  echo "error:$compact_output"
}

extract_unlock_pulse_ms() {
  local config_file="$1"
  if [[ ! -f "$config_file" ]]; then
    echo "15000"
    return
  fi

  local value
  value="$(sed -n 's/.*kUnlockPulseMs[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$config_file" | head -n 1)"
  if [[ -z "$value" ]]; then
    echo "15000"
    return
  fi

  echo "$value"
}

refresh_android_google_services_json() {
  local firebase_bin="$1"
  local project_id="$2"
  local android_app_id="$3"
  local output_file="$4"
  local output

  if [[ -z "$firebase_bin" ]]; then
    echo "skipped_no_cli"
    return
  fi

  if output="$("$firebase_bin" apps:sdkconfig ANDROID "$android_app_id" --project "$project_id" -o "$output_file" 2>&1)"; then
    echo "updated"
    return
  fi

  local compact_output
  compact_output="$(printf '%s' "$output" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  echo "error:$compact_output"
}

escape_c_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  echo "$value"
}

escape_dart_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  echo "$value"
}

echo "== Poot NodeMCU Secrets Initializer =="
echo

FLUTTERFIRE_BIN="$(resolve_flutterfire_bin)"
FIREBASE_BIN="$(resolve_firebase_bin)"
JQ_BIN="$(resolve_jq_bin)"
KEYTOOL_BIN="$(resolve_keytool_bin)"
if [[ -z "$FLUTTERFIRE_BIN" ]]; then
  echo "flutterfire CLI not found in PATH or ~/.pub-cache/bin."
  echo "Install it with: dart pub global activate flutterfire_cli"
  exit 1
fi

if [[ -z "$KEYTOOL_BIN" ]]; then
  echo "keytool not found. Install a JDK and ensure keytool is in PATH."
  exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "Flutter app directory not found at $APP_DIR"
  exit 1
fi

refresh_choice="$(prompt "Refresh app/lib/firebase_options.dart with flutterfire configure first? (y/n)" "y")"
if [[ "$refresh_choice" =~ ^[Yy]$ ]]; then
  project_id_input="$(prompt "Firebase project id" "")"
  if [[ -z "$project_id_input" ]]; then
    echo "Project id is required to run flutterfire configure."
    exit 1
  fi

  echo "Running flutterfire configure..."
  (
    cd "$APP_DIR"
    if ! "$FLUTTERFIRE_BIN" configure \
      --project="$project_id_input" \
      --platforms=android,ios \
      --android-package-name=com.rohittp.poot \
      --ios-bundle-id=com.rohittp.poot \
      --yes \
      --out=lib/firebase_options.dart; then
      echo
      echo "flutterfire configure failed."
      echo "If this is the xcodeproj Ruby error, install it with:"
      echo "  gem install --user-install xcodeproj"
      echo "Then re-run this script."
      exit 1
    fi
  )
fi

if [[ ! -f "$FIREBASE_OPTIONS_FILE" ]]; then
  echo "Missing $FIREBASE_OPTIONS_FILE"
  echo "Run flutterfire configure first, then retry."
  exit 1
fi

api_key="$(extract_android_option "apiKey")"
project_id="$(extract_android_option "projectId")"
android_app_id="$(extract_android_option "appId")"

if [[ -z "$api_key" || -z "$project_id" || -z "$android_app_id" ]]; then
  echo "Could not parse android apiKey/projectId/appId from $FIREBASE_OPTIONS_FILE"
  exit 1
fi

default_db_url="https://${project_id}-default-rtdb.firebaseio.com"
detected_db_url="$(detect_db_url_with_firebase_cli "$FIREBASE_BIN" "$project_id")"
if [[ -n "$detected_db_url" ]]; then
  default_db_url="$detected_db_url"
fi

echo
echo "Using FlutterFire app config:"
echo "  projectId: $project_id"
echo "  androidAppId: $android_app_id"
echo "  apiKey:    ${api_key:0:10}..."
echo

android_key_alias="poot_upload"
android_store_password=""
android_key_password=""
android_keystore_status="generated"

if [[ -f "$ANDROID_KEYSTORE_FILE" && -f "$ANDROID_KEY_PROPERTIES_FILE" ]]; then
  existing_alias="$(trim "$(read_properties_value "$ANDROID_KEY_PROPERTIES_FILE" "keyAlias")")"
  existing_store_password="$(trim "$(read_properties_value "$ANDROID_KEY_PROPERTIES_FILE" "storePassword")")"
  existing_key_password="$(trim "$(read_properties_value "$ANDROID_KEY_PROPERTIES_FILE" "keyPassword")")"

  if [[ -n "$existing_alias" && -n "$existing_store_password" && -n "$existing_key_password" ]]; then
    android_key_alias="$existing_alias"
    android_store_password="$existing_store_password"
    android_key_password="$existing_key_password"
    android_keystore_status="reused"
  fi
fi

if [[ -z "$android_store_password" || -z "$android_key_password" ]]; then
  android_store_password="$(generate_signing_password)"
  android_key_password="$(generate_signing_password)"
  android_key_alias="poot_upload"

  mkdir -p "$ANDROID_DIR"
  if [[ -f "$ANDROID_KEYSTORE_FILE" ]]; then
    mv "$ANDROID_KEYSTORE_FILE" "${ANDROID_KEYSTORE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  create_android_signing_keystore \
    "$KEYTOOL_BIN" \
    "$ANDROID_KEYSTORE_FILE" \
    "$android_store_password" \
    "$android_key_alias" \
    "$android_key_password" \
    "CN=Poot, OU=IoT, O=Poot, L=City, S=State, C=US"
fi

cat > "$ANDROID_KEY_PROPERTIES_FILE" <<KEYPROPS
# Generated by init.sh
storePassword=$android_store_password
keyPassword=$android_key_password
keyAlias=$android_key_alias
storeFile=../$(basename "$ANDROID_KEYSTORE_FILE")
KEYPROPS

if [[ -f "$ANDROID_KEYSTORE_FILE" ]]; then
  chmod 600 "$ANDROID_KEYSTORE_FILE"
fi
if [[ -f "$ANDROID_KEY_PROPERTIES_FILE" ]]; then
  chmod 600 "$ANDROID_KEY_PROPERTIES_FILE"
fi

android_sha1="$(extract_keystore_fingerprint "$KEYTOOL_BIN" "$ANDROID_KEYSTORE_FILE" "$android_key_alias" "$android_store_password" "$android_key_password" "SHA1")"
android_sha256="$(extract_keystore_fingerprint "$KEYTOOL_BIN" "$ANDROID_KEYSTORE_FILE" "$android_key_alias" "$android_store_password" "$android_key_password" "SHA256")"

if [[ -z "$android_sha1" || -z "$android_sha256" ]]; then
  echo "Failed to read Android signing key fingerprints from $ANDROID_KEYSTORE_FILE"
  exit 1
fi

android_sha1_register_status="$(register_android_sha_with_firebase "$FIREBASE_BIN" "$project_id" "$android_app_id" "$android_sha1")"
android_sha256_register_status="$(register_android_sha_with_firebase "$FIREBASE_BIN" "$project_id" "$android_app_id" "$android_sha256")"
android_google_services_refresh_status="$(refresh_android_google_services_json "$FIREBASE_BIN" "$project_id" "$android_app_id" "$APP_DIR/android/app/google-services.json")"

wifi_ssid="$(trim "$(prompt "Home Wi-Fi SSID" "")")"
if [[ -z "$wifi_ssid" ]]; then
  echo "Wi-Fi SSID is required."
  exit 1
fi

wifi_password="$(prompt_secret "Home Wi-Fi password")"
if [[ -z "$wifi_password" ]]; then
  echo "Wi-Fi password is required."
  exit 1
fi

ap_ssid="$(trim "$(prompt "Fallback AP SSID" "Poot-Lock")")"
ap_password="$(generate_ap_password)"

db_url="$(trim "$(prompt "Firebase Realtime Database URL" "$default_db_url")")"
if [[ -z "$db_url" ]]; then
  echo "Database URL is required."
  exit 1
fi

device_email="$(trim "$(prompt "Firebase device email" "device-lock@example.com")")"
if [[ -z "$device_email" ]]; then
  echo "Device email is required."
  exit 1
fi
device_email="$(printf '%s' "$device_email" | tr '[:upper:]' '[:lower:]')"

generated_device_password="$(generate_device_password)"
use_generated_device_password="$(prompt "Auto-generate Firebase device password? (y/n)" "y")"
if [[ "$use_generated_device_password" =~ ^[Yy]$ ]]; then
  device_password="$generated_device_password"
else
  device_password="$(prompt_secret "Firebase device password")"
fi

if [[ -z "$device_password" ]]; then
  echo "Device password is required."
  exit 1
fi

create_device_user_now="$(prompt "Try creating Firebase device user now? (y/n)" "y")"
if [[ "$create_device_user_now" =~ ^[Yy]$ ]]; then
  creation_status="$(try_create_device_user "$api_key" "$device_email" "$device_password")"
  case "$creation_status" in
    created)
      echo "Firebase Auth device user created."
      ;;
    exists)
      echo "Firebase Auth user already exists for $device_email."
      if [[ "$use_generated_device_password" =~ ^[Yy]$ ]]; then
        known_password_choice="$(prompt "Enter known existing password instead? (y/n)" "y")"
        if [[ "$known_password_choice" =~ ^[Yy]$ ]]; then
          device_password="$(prompt_secret "Existing Firebase device password")"
          if [[ -z "$device_password" ]]; then
            echo "Device password is required."
            exit 1
          fi
        fi
      fi
      ;;
    missing_curl)
      echo "Skipping device user creation: curl not found."
      ;;
    request_failed)
      echo "Device user creation request failed. Continuing with provided credentials."
      ;;
    error:OPERATION_NOT_ALLOWED)
      echo "Device user creation failed: OPERATION_NOT_ALLOWED."
      echo "Enable Firebase Auth -> Sign-in method -> Email/Password, then rerun init.sh."
      ;;
    error:INVALID_API_KEY)
      echo "Device user creation failed: INVALID_API_KEY."
      echo "Re-run flutterfire configure so firebase_options.dart has the latest apiKey."
      ;;
    error:PROJECT_NOT_FOUND)
      echo "Device user creation failed: PROJECT_NOT_FOUND."
      echo "Check selected Firebase project id and rerun init.sh."
      ;;
    error:TOO_MANY_ATTEMPTS_TRY_LATER)
      echo "Device user creation rate-limited. Retry in a few minutes."
      ;;
    error:*)
      echo "Device user creation failed with Firebase error: ${creation_status#error:}"
      echo "Continuing with provided credentials."
      ;;
    error_response:*)
      echo "Device user creation failed with raw response:"
      echo "${creation_status#error_response:}"
      echo "Continuing with provided credentials."
      ;;
    *)
      echo "Device user creation failed with status: $creation_status. Continuing."
      ;;
  esac
fi

lock_id="$(trim "$(prompt "Lock ID" "front-door")")"
if [[ -z "$lock_id" ]]; then
  echo "Lock ID is required."
  exit 1
fi

db_instance="$(detect_db_instance_from_url "$db_url")"
device_uid=""
if [[ -n "$FIREBASE_BIN" && -n "$JQ_BIN" ]]; then
  device_uid="$(resolve_uid_by_email "$FIREBASE_BIN" "$JQ_BIN" "$project_id" "$device_email")"
  device_account_seed_status="$(seed_device_account "$FIREBASE_BIN" "$JQ_BIN" "$project_id" "$lock_id" "$db_instance" "$device_uid" "$device_email")"
elif [[ -z "$FIREBASE_BIN" ]]; then
  device_account_seed_status="skipped_no_cli"
else
  device_account_seed_status="skipped_no_jq"
fi

local_secret="$(generate_secret)"

wifi_ssid_escaped="$(escape_c_string "$wifi_ssid")"
wifi_password_escaped="$(escape_c_string "$wifi_password")"
ap_ssid_escaped="$(escape_c_string "$ap_ssid")"
ap_password_escaped="$(escape_c_string "$ap_password")"
db_url_escaped="$(escape_c_string "$db_url")"
api_key_escaped="$(escape_c_string "$api_key")"
device_email_escaped="$(escape_c_string "$device_email")"
device_password_escaped="$(escape_c_string "$device_password")"
lock_id_escaped="$(escape_c_string "$lock_id")"
local_secret_escaped="$(escape_c_string "$local_secret")"
ap_ssid_dart_escaped="$(escape_dart_string "$ap_ssid")"
ap_password_dart_escaped="$(escape_dart_string "$ap_password")"
local_secret_dart_escaped="$(escape_dart_string "$local_secret")"
lock_id_dart_escaped="$(escape_dart_string "$lock_id")"
unlock_pulse_ms="$(extract_unlock_pulse_ms "$NODEMCU_CONFIG_FILE")"

mkdir -p "$(dirname "$SECRETS_FILE")"
mkdir -p "$(dirname "$FLUTTER_LOCAL_DEFAULTS_FILE")"

cat > "$SECRETS_FILE" <<SECRETS
#pragma once

// Generated by init.sh

#define WIFI_STA_SSID "$wifi_ssid_escaped"
#define WIFI_STA_PASSWORD "$wifi_password_escaped"

#define AP_SSID "$ap_ssid_escaped"
#define AP_PASSWORD "$ap_password_escaped"

#define FIREBASE_DB_URL "$db_url_escaped"
#define FIREBASE_API_KEY "$api_key_escaped"
#define FIREBASE_DEVICE_EMAIL "$device_email_escaped"
#define FIREBASE_DEVICE_PASSWORD "$device_password_escaped"

#define LOCK_ID "$lock_id_escaped"
#define LOCAL_SHARED_SECRET "$local_secret_escaped"
SECRETS

cat > "$FLUTTER_LOCAL_DEFAULTS_FILE" <<DARTCFG
/// Generated by \`init.sh\`.
/// Do not hand-edit; run the initializer again.
class LocalFallbackDefaults {
  const LocalFallbackDefaults._();

  static const String lockId = '$lock_id_dart_escaped';
  static const String baseUrl = 'http://192.168.4.1';
  static const String espSsid = '$ap_ssid_dart_escaped';
  static const String espPassword = '$ap_password_dart_escaped';
  static const String sharedSecret = '$local_secret_dart_escaped';
  static const int unlockPulseMs = $unlock_pulse_ms;
}
DARTCFG

chmod 600 "$SECRETS_FILE"

echo
echo "Generated: $SECRETS_FILE"
echo "Generated: $FLUTTER_LOCAL_DEFAULTS_FILE"
echo "Android signing keystore ($android_keystore_status): $ANDROID_KEYSTORE_FILE"
echo "Android signing key properties: $ANDROID_KEY_PROPERTIES_FILE"
echo "Android signing alias: $android_key_alias"
echo "Android signing SHA1: $android_sha1"
echo "Android signing SHA256: $android_sha256"
echo "Generated fallback AP SSID: $ap_ssid"
echo "Generated fallback AP password: $ap_password"
echo "Firebase DB URL: $db_url"
echo "Firebase API key (from FlutterFire): ${api_key:0:10}..."
echo "Firebase device email: $device_email"
echo "Firebase device password: $device_password"
echo "Firebase device UID: ${device_uid:-not_found}"
echo "Device account seed status: $device_account_seed_status"
echo "Generated LOCAL_SHARED_SECRET: $local_secret"
echo "Firebase SHA1 registration: $android_sha1_register_status"
echo "Firebase SHA256 registration: $android_sha256_register_status"
echo "google-services.json refresh: $android_google_services_refresh_status"
echo

echo "Next steps:"
echo "  1) Find serial port:"
echo "     arduino-cli board list"
echo "     # optional: arduino-cli board list | grep -E '/dev/cu\\.|/dev/tty\\.'"
echo "  2) Flash firmware:"
echo "     arduino-cli upload -p <PORT_FROM_ABOVE> --fqbn esp8266:esp8266:nodemcuv2 $ROOT_DIR/nodemcu/poot_lock"
echo "  3) Run app:"
echo "     cd $APP_DIR && flutter run"
