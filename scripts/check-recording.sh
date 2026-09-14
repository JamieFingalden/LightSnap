#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${PROJECT_DIR}/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_DIR}/.build/swift-cache"
swift build --package-path "${PROJECT_DIR}" --disable-sandbox
BIN_DIR="$(swift build --package-path "${PROJECT_DIR}" --show-bin-path)"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    -module-cache-path "${CLANG_MODULE_CACHE_PATH}" -I "${BIN_DIR}/Modules" \
    "${PROJECT_DIR}/Sources/LightSnap/CaptureService.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/ElementLocator.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/FloatingTools.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/RecordingDocument.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/RecordingCapture.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/RecordingRender.swift" \
    "${PROJECT_DIR}/scripts/RecordingCheck.swift" \
    "${BIN_DIR}/CaptureCore.build/"*.swift.o -o "${PROJECT_DIR}/.build/check-recording"
"${PROJECT_DIR}/.build/check-recording" "${PROJECT_DIR}/.build/recording-check"
