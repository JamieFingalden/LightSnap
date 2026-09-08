#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${PROJECT_DIR}/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_DIR}/.build/swift-cache"
echo "正在构建轻截 Apple Silicon 版本…"
swift build --package-path "${PROJECT_DIR}" -c release --arch arm64 --disable-sandbox
BIN_DIR="$(swift build --package-path "${PROJECT_DIR}" -c release --arch arm64 --show-bin-path)"
APP_DIR="${PROJECT_DIR}/dist/LightSnap.app"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
install -m 755 "${BIN_DIR}/LightSnap" "${APP_DIR}/Contents/MacOS/LightSnap"
install -m 644 "${PROJECT_DIR}/Support/Info.plist" "${APP_DIR}/Contents/Info.plist"
swift "${PROJECT_DIR}/scripts/icon.swift" "${PROJECT_DIR}/.build"
iconutil -c icns "${PROJECT_DIR}/.build/AppIcon.iconset" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
codesign --force --sign "${LIGHTSNAP_SIGN_IDENTITY:--}" "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"
if [[ -z "${LIGHTSNAP_SIGN_IDENTITY:-}" ]]; then
    echo "当前使用临时签名；更新后若屏幕录制授权失效，请删除旧授权条目并重新添加此应用。"
fi
echo "构建完成：${APP_DIR}"
