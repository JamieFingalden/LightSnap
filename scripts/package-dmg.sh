#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
APP_DIR="${PROJECT_DIR}/dist/LightSnap.app"
if [[ ! -d "${APP_DIR}" ]]; then
    echo "请先运行 zsh scripts/build.sh 构建应用。" >&2
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_DIR}/Contents/Info.plist")"
DMG_NAME="LightSnap-${VERSION}-arm64.dmg"
STAGING_DIR="$(mktemp -d "${PROJECT_DIR}/.build/dmg.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT
codesign --verify --deep --strict "${APP_DIR}"
ditto "${APP_DIR}" "${STAGING_DIR}/LightSnap.app"
ln -s /Applications "${STAGING_DIR}/Applications"
install -m 644 "${PROJECT_DIR}/docs/INSTALL.txt" "${STAGING_DIR}/安装说明.txt"
install -m 644 "${PROJECT_DIR}/LICENSE" "${STAGING_DIR}/LICENSE"
hdiutil create -volname "LightSnap ${VERSION}" -srcfolder "${STAGING_DIR}" \
    -fs HFS+ -format UDZO -ov "${PROJECT_DIR}/dist/${DMG_NAME}"
hdiutil verify "${PROJECT_DIR}/dist/${DMG_NAME}"
cd "${PROJECT_DIR}/dist"
shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
echo "安装包已生成：${PROJECT_DIR}/dist/${DMG_NAME}"
