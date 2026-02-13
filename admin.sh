#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_DEFAULTS_FILE="$ROOT_DIR/app/lib/src/config/local_fallback_defaults.dart"
FIREBASERC_FILE="$ROOT_DIR/.firebaserc"

usage() {
  cat <<'EOF'
Usage:
  ./admin.sh <admin_email> [--device-email <device_email>] [--lock-id <lock_id>] [--project <project_id>] [--instance <db_instance>]
  ./admin.sh --device-email <device_email> [--lock-id <lock_id>] [--project <project_id>] [--instance <db_instance>]

Examples:
  ./admin.sh user@example.com
  ./admin.sh user@example.com --device-email lock-device@example.com
  ./admin.sh --device-email lock-device@example.com --lock-id front-door
EOF
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

parse_default_lock_id() {
  if [[ ! -f "$LOCK_DEFAULTS_FILE" ]]; then
    echo ""
    return
  fi

  sed -n "s/.*static const String lockId = '\([^']*\)'.*/\1/p" "$LOCK_DEFAULTS_FILE" \
    | head -n 1
}

parse_default_project_id() {
  if [[ ! -f "$FIREBASERC_FILE" ]]; then
    echo ""
    return
  fi

  sed -n 's/.*"default"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$FIREBASERC_FILE" \
    | head -n 1
}

normalize_email() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_valid_email() {
  local email="$1"
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

lookup_uid_in_export() {
  local jq_bin="$1"
  local export_file="$2"
  local email="$3"

  "$jq_bin" -r --arg email "$email" '
    .users[]? | select((.email // "" | ascii_downcase) == ($email | ascii_downcase)) | .localId
  ' "$export_file" | head -n 1
}

admin_email=""
device_email=""
lock_id=""
project_id=""
instance=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --device-email)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --device-email"
        usage
        exit 1
      fi
      device_email="$2"
      shift 2
      ;;
    --lock-id)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --lock-id"
        usage
        exit 1
      fi
      lock_id="$2"
      shift 2
      ;;
    --project)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --project"
        usage
        exit 1
      fi
      project_id="$2"
      shift 2
      ;;
    --instance)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --instance"
        usage
        exit 1
      fi
      instance="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$admin_email" ]]; then
        echo "Unexpected extra argument: $1"
        usage
        exit 1
      fi
      admin_email="$1"
      shift
      ;;
  esac
done

if [[ -z "$admin_email" && -z "$device_email" ]]; then
  echo "Provide <admin_email> and/or --device-email <email>."
  usage
  exit 1
fi

if [[ -n "$admin_email" ]] && ! is_valid_email "$admin_email"; then
  echo "Invalid admin email format: $admin_email"
  exit 1
fi
if [[ -n "$device_email" ]] && ! is_valid_email "$device_email"; then
  echo "Invalid device email format: $device_email"
  exit 1
fi

admin_email="$(normalize_email "$admin_email")"
device_email="$(normalize_email "$device_email")"

FIREBASE_BIN="$(resolve_firebase_bin)"
if [[ -z "$FIREBASE_BIN" ]]; then
  echo "firebase CLI not found. Install: npm install -g firebase-tools"
  exit 1
fi

JQ_BIN="$(resolve_jq_bin)"
if [[ -z "$JQ_BIN" ]]; then
  echo "jq not found. Install: brew install jq"
  exit 1
fi

if [[ -z "$project_id" ]]; then
  project_id="$(parse_default_project_id)"
fi
if [[ -z "$project_id" ]]; then
  echo "Could not detect Firebase project id. Pass --project <project_id>."
  exit 1
fi

if [[ -z "$lock_id" ]]; then
  lock_id="$(parse_default_lock_id)"
fi
if [[ -z "$lock_id" ]]; then
  lock_id="front-door"
fi

tmp_users_file="$(mktemp)"
cleanup() {
  rm -f "$tmp_users_file"
}
trap cleanup EXIT

echo "Exporting Firebase Auth users from project '$project_id'..."
"$FIREBASE_BIN" auth:export "$tmp_users_file" --project "$project_id" --format=json >/dev/null

users_status="skipped"
identity_status="skipped"
device_status="skipped"
admin_uid=""
device_uid=""

if [[ -n "$admin_email" ]]; then
  admin_uid="$(lookup_uid_in_export "$JQ_BIN" "$tmp_users_file" "$admin_email")"
  if [[ -z "$admin_uid" || "$admin_uid" == "null" ]]; then
    echo "No Firebase Auth user found for admin email: $admin_email"
    exit 1
  fi

  updated_at="$(date +%s)"
  user_payload="$("$JQ_BIN" -cn --arg role "admin" --argjson enabled true --argjson updatedAt "$updated_at" '
    {role: $role, enabled: $enabled, updatedAt: $updatedAt}
  ')"
  identity_payload="$("$JQ_BIN" -cn --arg email "$admin_email" --argjson updatedAt "$updated_at" '
    {email: $email, updatedAt: $updatedAt}
  ')"

  users_path="/locks/$lock_id/users/$admin_uid"
  identity_path="/locks/$lock_id/identity/$admin_uid"

  users_cmd=("$FIREBASE_BIN" database:update "$users_path" --project "$project_id" --data "$user_payload" --force)
  identity_cmd=("$FIREBASE_BIN" database:update "$identity_path" --project "$project_id" --data "$identity_payload" --force)
  if [[ -n "$instance" ]]; then
    users_cmd+=(--instance "$instance")
    identity_cmd+=(--instance "$instance")
  fi

  echo "Granting admin role at '$users_path'..."
  if "${users_cmd[@]}" >/dev/null; then
    users_status="ok"
  else
    users_status="failed"
  fi

  echo "Seeding identity at '$identity_path'..."
  if "${identity_cmd[@]}" >/dev/null; then
    identity_status="ok"
  else
    identity_status="failed"
  fi
fi

if [[ -n "$device_email" ]]; then
  device_uid="$(lookup_uid_in_export "$JQ_BIN" "$tmp_users_file" "$device_email")"
  if [[ -z "$device_uid" || "$device_uid" == "null" ]]; then
    echo "No Firebase Auth user found for device email: $device_email"
    exit 1
  fi

  updated_at="$(date +%s)"
  device_payload="$("$JQ_BIN" -cn --arg uid "$device_uid" --arg email "$device_email" --argjson enabled true --argjson updatedAt "$updated_at" '
    {uid: $uid, email: $email, enabled: $enabled, updatedAt: $updatedAt}
  ')"
  device_path="/locks/$lock_id/deviceAccount"
  device_cmd=("$FIREBASE_BIN" database:update "$device_path" --project "$project_id" --data "$device_payload" --force)
  if [[ -n "$instance" ]]; then
    device_cmd+=(--instance "$instance")
  fi

  echo "Setting device account at '$device_path'..."
  if "${device_cmd[@]}" >/dev/null; then
    device_status="ok"
  else
    device_status="failed"
  fi
fi

if [[ "$users_status" == "failed" || "$identity_status" == "failed" || "$device_status" == "failed" ]]; then
  echo
  echo "Failed."
  echo "  users write status:    $users_status"
  echo "  identity write status: $identity_status"
  echo "  device write status:   $device_status"
  exit 1
fi

echo
echo "Done."
echo "  Project: $project_id"
echo "  Lock ID: $lock_id"
if [[ -n "$admin_email" ]]; then
  echo "  Admin email: $admin_email"
  echo "  Admin UID:   $admin_uid"
  echo "  users status:    $users_status"
  echo "  identity status: $identity_status"
fi
if [[ -n "$device_email" ]]; then
  echo "  Device email: $device_email"
  echo "  Device UID:   $device_uid"
  echo "  device status: $device_status"
fi
