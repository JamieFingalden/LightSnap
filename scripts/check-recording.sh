#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${PROJECT_DIR}/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_DIR}/.build/swift-cache"
swift build --package-path "${PROJECT_DIR}" --disable-sandbox
BIN_DIR="$(swift build --package-path "${PROJECT_DIR}" --show-bin-path)"
# 新旧 SwiftPM 产物布局：模块可能在 Modules/ 或产物目录本身，CaptureCore 可能是逐文件对象或单个 CaptureCore.o。
MODULE_DIR="${BIN_DIR}/Modules"; [[ -d "${MODULE_DIR}" ]] || MODULE_DIR="${BIN_DIR}"
CORE_OBJECTS=("${BIN_DIR}"/CaptureCore.build/*.swift.o(N)); (( ${#CORE_OBJECTS} )) || CORE_OBJECTS=("${BIN_DIR}/CaptureCore.o")
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    -module-cache-path "${CLANG_MODULE_CACHE_PATH}" -I "${MODULE_DIR}" \
    "${PROJECT_DIR}/Sources/LightSnap/CaptureService.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/ElementLocator.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/FloatingTools.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/RecordingDocument.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/RecordingCapture.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/RecordingRender.swift" \
    "${PROJECT_DIR}/scripts/RecordingCheck.swift" \
    "${CORE_OBJECTS[@]}" -o "${PROJECT_DIR}/.build/check-recording"
"${PROJECT_DIR}/.build/check-recording" "${PROJECT_DIR}/.build/recording-check"
