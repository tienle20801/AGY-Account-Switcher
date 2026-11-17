#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="AGY Account Switcher"
EXECUTABLE_NAME="AGYAutoChanger"
WATCHER_NAME="AGYWatcher"
BUILD_ROOT="${DESKTOP_DIR}/build"
APP_BUNDLE="${BUILD_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

cd "${DESKTOP_DIR}"

echo "==> Building ${EXECUTABLE_NAME} & ${WATCHER_NAME} (release)..."
swift build -c release --product "${EXECUTABLE_NAME}"
swift build -c release --product "${WATCHER_NAME}"

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="${BIN_DIR}/${EXECUTABLE_NAME}"
WATCHER_BIN_PATH="${BIN_DIR}/${WATCHER_NAME}"

if [[ ! -f "${BIN_PATH}" ]]; then
    echo "Error: compiled binary not found at ${BIN_PATH}" >&2
    exit 1
fi

if [[ ! -f "${WATCHER_BIN_PATH}" ]]; then
    echo "Error: compiled watcher binary not found at ${WATCHER_BIN_PATH}" >&2
    exit 1
fi

echo "==> Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}" "${BUILD_ROOT}/AGY Auto Changer.app"
mkdir -p "${MACOS_DIR}" "${HELPERS_DIR}" "${RESOURCES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"
cp "${WATCHER_BIN_PATH}" "${HELPERS_DIR}/${WATCHER_NAME}"
chmod +x "${HELPERS_DIR}/${WATCHER_NAME}"

cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AGYAutoChanger</string>
    <key>CFBundleIdentifier</key>
    <string>com.agy.autochanger</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AGY Account Switcher</string>
    <key>CFBundleDisplayName</key>
    <string>AGY Account Switcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Ad-hoc codesigning ${APP_BUNDLE}..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Built app bundle successfully at:"
echo "    ${APP_BUNDLE}"
