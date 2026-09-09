#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${PROJECT_DIR}/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_DIR}/.build/swift-cache"
BIN_DIR="$(swift build --package-path "${PROJECT_DIR}" -c release --arch arm64 --show-bin-path)"
cat > "${PROJECT_DIR}/.build/PinWindowCheck.swift" <<'SWIFT'
import AppKit
import CaptureCore

@main
struct PinWindowCheck {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let context = try ImageCodec.context(width: 600, height: 400)
        let controller = PinnedImageWindow(image: context.makeImage()!, frame: CGRect(x: 100, y: 100, width: 602, height: 402))
        let window = controller.window!
        let content = window.contentView!
        let scroll = content.subviews.compactMap { $0 as? NSScrollView }.first!
        let imageView = scroll.documentView!
        let originalSize = window.frame.size
        let zoomOut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "-", charactersIgnoringModifiers: "-", isARepeat: false, keyCode: 27)!
        for _ in 0..<3 {
            precondition(imageView.performKeyEquivalent(with: zoomOut), "缩小快捷键未响应")
            let imageBounds = imageView.convert(imageView.bounds, to: content)
            precondition(window.frame.width < originalSize.width, "缩小图片后窗口仍保留原宽度")
            precondition(abs(window.frame.width - imageBounds.width - 2) <= 1, "贴图左右仍有多余外框：窗口 \(window.frame.width)，图片 \(imageBounds.width)")
            precondition(abs(window.frame.height - imageBounds.height - 2) <= 1, "贴图上下仍有多余外框：窗口 \(window.frame.height)，图片 \(imageBounds.height)")
            precondition(window.screen!.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame), "贴图超出屏幕可用范围")
        }
        let zoomIn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "=", charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24)!
        for _ in 0..<20 { _ = imageView.performKeyEquivalent(with: zoomIn) }
        precondition(window.screen!.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame), "放大后的贴图超出屏幕可用范围")
        precondition(content.subviews.allSatisfy { !($0 is NSButton) }, "贴图不应保留关闭按钮")
        var closed = false
        controller.onClose = { closed = true }
        let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        imageView.mouseDown(with: doubleClick)
        precondition(closed, "双击未关闭贴图")

        let menuController = PinnedImageWindow(image: context.makeImage()!, frame: CGRect(x: 100, y: 100, width: 602, height: 402))
        let menuScroll = menuController.window!.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!
        let closeItem = menuScroll.documentView!.menu!.items.first { $0.title == "关闭该贴图" }!
        closed = false
        menuController.onClose = { closed = true }
        NSApp.sendAction(closeItem.action!, to: closeItem.target, from: closeItem)
        precondition(closed, "菜单未关闭贴图")
        print("贴图检查通过：缩放贴合、屏幕边界、双击关闭、菜单关闭。")
    }
}
SWIFT
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    -module-cache-path "${CLANG_MODULE_CACHE_PATH}" -I "${BIN_DIR}/Modules" \
    "${PROJECT_DIR}/Sources/LightSnap/CaptureService.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/ElementLocator.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/FloatingTools.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/PinnedImageWindow.swift" \
    "${PROJECT_DIR}/.build/PinWindowCheck.swift" \
    "${BIN_DIR}/CaptureCore.build/"*.swift.o -o "${PROJECT_DIR}/.build/check-pin"
"${PROJECT_DIR}/.build/check-pin"
