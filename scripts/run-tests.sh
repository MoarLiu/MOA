#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sources.env
source "$ROOT/scripts/sources.env"
# shellcheck source=version.env
source "$ROOT/scripts/version.env"
BUILD_DIR="$ROOT/build/tests"
EXECUTABLE="$BUILD_DIR/moa-core-tests"

resolve_swiftc() {
  if [[ -n "${SWIFTC:-}" ]]; then
    if [[ ! -x "$SWIFTC" ]]; then
      echo "SWIFTC is not executable: $SWIFTC" >&2
      exit 1
    fi
    SWIFTC_BIN="$SWIFTC"
    SDKROOT="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
    if [[ -z "$SDKROOT" || ! -d "$SDKROOT" ]]; then
      echo "Unable to locate the macOS SDK. Set SDKROOT or DEVELOPER_DIR to a full Xcode toolchain." >&2
      exit 1
    fi
    return
  fi

  local selected_developer_dir
  selected_developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [[ -z "${DEVELOPER_DIR:-}" ]] &&
     [[ "$selected_developer_dir" == "/Library/Developer/CommandLineTools" ]] &&
     [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    echo "Using full Xcode toolchain for SwiftUI macro support: $DEVELOPER_DIR" >&2
  fi

  SWIFTC_BIN="$(/usr/bin/xcrun --find swiftc 2>/dev/null || true)"
  if [[ -z "$SWIFTC_BIN" || ! -x "$SWIFTC_BIN" ]]; then
    echo "Unable to locate swiftc. Set SWIFTC or DEVELOPER_DIR to a full Xcode toolchain." >&2
    exit 1
  fi
  SDKROOT="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
  if [[ -z "$SDKROOT" || ! -d "$SDKROOT" ]]; then
    echo "Unable to locate the macOS SDK. Set SDKROOT or DEVELOPER_DIR to a full Xcode toolchain." >&2
    exit 1
  fi
}

MOA_TEST_ABS_SOURCES=()
for source in "${MOA_TEST_SUPPORT_SOURCES[@]}"; do
  MOA_TEST_ABS_SOURCES+=("$ROOT/$source")
done

validate_source_lists() {
  local expected_app_sources=()
  local source
  while IFS= read -r -d '' source; do
    expected_app_sources+=("${source#$ROOT/}")
  done < <(find "$ROOT/macos-menu-bar" -maxdepth 1 -name "*.swift" -print0 | sort -z)

  local declared_app_sources
  local expected_app_joined
  declared_app_sources="$(printf '%s\n' "${MOA_APP_SOURCES[@]}" | sort)"
  expected_app_joined="$(printf '%s\n' "${expected_app_sources[@]}" | sort)"
  if [[ "$declared_app_sources" != "$expected_app_joined" ]]; then
    echo "MOA_APP_SOURCES is out of sync with macos-menu-bar/*.swift" >&2
    diff -u <(printf '%s\n' "$expected_app_joined") <(printf '%s\n' "$declared_app_sources") >&2 || true
    exit 1
  fi

  local declared_test_sources
  declared_test_sources="$(printf '%s\n' "${MOA_TEST_SUPPORT_SOURCES[@]}" | sort)"
  if [[ "$declared_test_sources" != "$declared_app_sources" ]]; then
    echo "MOA_TEST_SUPPORT_SOURCES must mirror MOA_APP_SOURCES so Moa.swift stays test-compiled." >&2
    diff -u <(printf '%s\n' "$declared_app_sources") <(printf '%s\n' "$declared_test_sources") >&2 || true
    exit 1
  fi

  for source in "${MOA_APP_SOURCES[@]}" "${MOA_TEST_SUPPORT_SOURCES[@]}"; do
    if [[ ! -f "$ROOT/$source" ]]; then
      echo "Source list references a missing file: $source" >&2
      exit 1
    fi
  done
}

mkdir -p "$BUILD_DIR"
resolve_swiftc
validate_source_lists
/usr/bin/plutil -lint \
  "$ROOT/assets/Localization/en.lproj/Localizable.strings" \
  "$ROOT/assets/Localization/zh-Hans.lproj/Localizable.strings" \
  >/dev/null

MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" "$SWIFTC_BIN" \
  -target "$SWIFTC_TARGET" \
  -sdk "$SDKROOT" \
  -D MOA_TESTING \
  -parse-as-library \
  -framework AppKit \
  -framework AVFoundation \
  -framework Combine \
  -framework CryptoKit \
  -framework Foundation \
  -framework ImageIO \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  "${MOA_TEST_ABS_SOURCES[@]}" \
  "$ROOT/Tests/MoaCoreTests.swift" \
  -o "$EXECUTABLE"

"$EXECUTABLE"
