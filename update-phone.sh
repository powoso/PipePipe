#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$ROOT_DIR/PipePipeClient"
GRADLE_USER_HOME_DEFAULT="$ROOT_DIR/.gradle-client"

DEVICE_SERIAL=""
USE_UNIVERSAL_APK=0

usage() {
  cat <<'EOF'
Usage: ./update-phone.sh [--device SERIAL] [--universal] [--help]

Builds PipePipe Daily locally and installs it on the connected Android device.

Options:
  --device SERIAL  Install to a specific adb device or emulator serial
  --universal      Always install the universal APK instead of an ABI-specific APK
  --help           Show this help text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --device" >&2
        exit 1
      fi
      DEVICE_SERIAL="$2"
      shift 2
      ;;
    --universal)
      USE_UNIVERSAL_APK=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

find_adb() {
  if [[ -n "${ADB:-}" && -x "${ADB}" ]]; then
    printf '%s\n' "${ADB}"
    return
  fi

  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return
  fi

  if [[ -n "${ANDROID_SDK_ROOT:-}" && -x "${ANDROID_SDK_ROOT}/platform-tools/adb" ]]; then
    printf '%s\n' "${ANDROID_SDK_ROOT}/platform-tools/adb"
    return
  fi

  if [[ -n "${ANDROID_HOME:-}" && -x "${ANDROID_HOME}/platform-tools/adb" ]]; then
    printf '%s\n' "${ANDROID_HOME}/platform-tools/adb"
    return
  fi

  if [[ -x "${HOME}/Library/Android/sdk/platform-tools/adb" ]]; then
    printf '%s\n' "${HOME}/Library/Android/sdk/platform-tools/adb"
    return
  fi

  return 1
}

ADB_BIN="$(find_adb || true)"
if [[ -z "${ADB_BIN}" ]]; then
  echo "Could not find adb. Install Android platform-tools or set ADB/ANDROID_SDK_ROOT." >&2
  exit 1
fi

run_adb() {
  if [[ -n "${DEVICE_SERIAL}" ]]; then
    "${ADB_BIN}" -s "${DEVICE_SERIAL}" "$@"
  else
    "${ADB_BIN}" "$@"
  fi
}

select_device_if_needed() {
  if [[ -n "${DEVICE_SERIAL}" ]]; then
    return
  fi

  connected_devices=()
  while IFS= read -r serial; do
    if [[ -n "${serial}" ]]; then
      connected_devices+=("${serial}")
    fi
  done < <("${ADB_BIN}" devices | awk 'NR > 1 && $2 == "device" { print $1 }')

  if [[ ${#connected_devices[@]} -eq 0 ]]; then
    echo "No connected Android devices found." >&2
    exit 1
  fi

  if [[ ${#connected_devices[@]} -gt 1 ]]; then
    echo "Multiple adb devices are connected. Re-run with --device SERIAL." >&2
    printf '  %s\n' "${connected_devices[@]}" >&2
    exit 1
  fi

  DEVICE_SERIAL="${connected_devices[0]}"
}

detect_abi_tag() {
  local abi_list
  abi_list="$(run_adb shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r')"

  case "${abi_list}" in
    *arm64-v8a*) printf '%s\n' "arm64-v8a" ;;
    *armeabi-v7a*) printf '%s\n' "armeabi-v7a" ;;
    *x86_64*) printf '%s\n' "x86_64" ;;
    *x86*) printf '%s\n' "x86" ;;
    *) printf '%s\n' "universal" ;;
  esac
}

pick_apk_path() {
  local abi_tag="$1"
  local preferred_apk="$CLIENT_DIR/app/build/outputs/apk/debug/PipePipe_daily-${abi_tag}-debug.apk"
  local universal_apk="$CLIENT_DIR/app/build/outputs/apk/debug/PipePipe_daily-universal-debug.apk"

  if [[ "${USE_UNIVERSAL_APK}" -eq 0 && -f "${preferred_apk}" ]]; then
    printf '%s\n' "${preferred_apk}"
    return
  fi

  if [[ -f "${universal_apk}" ]]; then
    printf '%s\n' "${universal_apk}"
    return
  fi

  if [[ -f "${preferred_apk}" ]]; then
    printf '%s\n' "${preferred_apk}"
    return
  fi

  echo "Could not find a built APK for abi '${abi_tag}'." >&2
  exit 1
}

select_device_if_needed

ABI_TAG="universal"
if [[ "${USE_UNIVERSAL_APK}" -eq 0 ]]; then
  ABI_TAG="$(detect_abi_tag)"
fi

echo "Building PipePipe Daily for ${DEVICE_SERIAL}..."
(
  cd "${CLIENT_DIR}"
  GRADLE_USER_HOME="${GRADLE_USER_HOME:-${GRADLE_USER_HOME_DEFAULT}}" ./gradlew :app:assembleDebug
)

APK_PATH="$(pick_apk_path "${ABI_TAG}")"

echo "Installing $(basename "${APK_PATH}") on ${DEVICE_SERIAL}..."
run_adb install -r "${APK_PATH}"

echo "PipePipe Daily is updated on ${DEVICE_SERIAL}."
