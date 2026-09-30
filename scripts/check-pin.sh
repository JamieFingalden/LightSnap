#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${PROJECT_DIR}/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_DIR}/.build/swift-cache"
# --show-bin-path 不触发编译，全新检出的环境必须先真正构建出模块。
swift build --package-path "${PROJECT_DIR}" -c release --arch arm64 --disable-sandbox
BIN_DIR="$(swift build --package-path "${PROJECT_DIR}" -c release --arch arm64 --show-bin-path)"
# 新旧 SwiftPM 产物布局：模块可能在 Modules/ 或产物目录本身，CaptureCore 可能是逐文件对象或单个 CaptureCore.o。
MODULE_DIR="${BIN_DIR}/Modules"; [[ -d "${MODULE_DIR}" ]] || MODULE_DIR="${BIN_DIR}"
CORE_OBJECTS=("${BIN_DIR}"/CaptureCore.build/*.swift.o(N)); (( ${#CORE_OBJECTS} )) || CORE_OBJECTS=("${BIN_DIR}/CaptureCore.o")
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
        for _ in 0..<20 { _ = imageView.performKeyEquivalent(with: zoomOut) }
        let beforeWheel = window.frame.size
        // 鼠标滚轮：向前推为放大，反向为缩小；带 ⌥ 时交给滚动视图。
        func wheel(_ lines: Int32, flags: CGEventFlags = []) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
            cg.flags = flags
            return NSEvent(cgEvent: cg)!
        }
        let up = wheel(3)
        let physicalUp = up.isDirectionInvertedFromDevice ? -up.scrollingDeltaY : up.scrollingDeltaY
        imageView.scrollWheel(with: physicalUp > 0 ? up : wheel(-3))
        precondition(window.frame.width > beforeWheel.width, "滚轮向前推未放大贴图")
        imageView.scrollWheel(with: physicalUp > 0 ? wheel(-3) : up)
        precondition(abs(window.frame.width - beforeWheel.width) <= 1, "滚轮反向未恢复大小")
        imageView.scrollWheel(with: wheel(3, flags: .maskAlternate))
        precondition(abs(window.frame.width - beforeWheel.width) <= 1, "⌥ + 滚轮不应缩放")
        var imageBounds = imageView.convert(imageView.bounds, to: content)
        precondition(abs(window.frame.width - imageBounds.width - 2) <= 1 && abs(window.frame.height - imageBounds.height - 2) <= 1, "滚轮缩放后边框未贴合图片")
        // 捏合：用系统手势字段合成事件，验证 magnify 路径与去重。
        func pinch(_ zoom: Double, timestamp: Int64) -> NSEvent {
            let cg = CGEvent(source: nil)!
            cg.type = CGEventType(rawValue: 29)!
            cg.timestamp = CGEventTimestamp(timestamp)
            cg.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
            cg.setIntegerValueField(CGEventField(rawValue: 132)!, value: 2)
            cg.setDoubleValueField(CGEventField(rawValue: 113)!, value: zoom)
            return NSEvent(cgEvent: cg)!
        }
        let grow = pinch(0.5, timestamp: 1_000_000_000)
        precondition(grow.type == .magnify && abs(grow.magnification - 0.5) < 0.001, "合成捏合事件未被识别为 magnify")
        imageView.magnify(with: grow)
        precondition(window.frame.width > beforeWheel.width * 1.4, "捏合未放大贴图：\(window.frame.width) vs \(beforeWheel.width)")
        let afterPinch = window.frame.width
        imageView.magnify(with: grow)
        precondition(abs(window.frame.width - afterPinch) <= 1, "同一捏合事件被重复应用")
        imageView.magnify(with: pinch(-1 / 3, timestamp: 2_000_000_000))
        precondition(abs(window.frame.width - beforeWheel.width) <= 1, "捏合缩小后未恢复：\(window.frame.width) vs \(beforeWheel.width)")
        imageBounds = imageView.convert(imageView.bounds, to: content)
        precondition(abs(window.frame.width - imageBounds.width - 2) <= 1, "捏合后边框未贴合图片")
        precondition(window.screen!.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame), "捏合后的贴图超出屏幕可用范围")
        // 后台捏合：轻截不在前台时，事件 tap 应把落在贴图上的捏合转发给贴图。需要终端已有辅助功能或输入监控权限。
        if CGPreflightListenEventAccess() || AXIsProcessTrusted() {
            controller.present()
            precondition(PinGestureTap.isActive, "有权限时未安装手势 tap")
            let screenHeight = NSScreen.screens[0].frame.height
            let point = CGPoint(x: window.frame.midX, y: screenHeight - window.frame.midY)
            let mouse = NSEvent.mouseLocation
            CGWarpMouseCursorPosition(point)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            let beforeTap = window.frame.width
            for (phase, zoom) in [(1, 0.2), (2, 0.2), (4, 0.0)] {
                let cg = CGEvent(source: nil)!
                cg.type = CGEventType(rawValue: 29)!
                cg.location = point
                cg.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
                cg.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(phase))
                cg.setDoubleValueField(CGEventField(rawValue: 113)!, value: zoom)
                cg.post(tap: .cghidEventTap)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
            CGWarpMouseCursorPosition(CGPoint(x: mouse.x, y: screenHeight - mouse.y))
            precondition(NSRunningApplication.current.isActive == false || NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), "检查进程不应成为前台应用")
            precondition(window.frame.width > beforeTap * 1.3, "后台捏合未经事件 tap 转发到贴图：\(window.frame.width) vs \(beforeTap)")
            print("后台捏合转发检查通过。")
        } else {
            print("终端没有辅助功能或输入监控权限，跳过后台捏合转发检查。")
        }
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
        print("贴图检查通过：快捷键、滚轮与捏合缩放贴合、屏幕边界、双击关闭、菜单关闭。")
    }
}
SWIFT
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    -module-cache-path "${CLANG_MODULE_CACHE_PATH}" -I "${MODULE_DIR}" \
    "${PROJECT_DIR}/Sources/LightSnap/CaptureService.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/ElementLocator.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/FloatingTools.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/PinnedImageWindow.swift" \
    "${PROJECT_DIR}/.build/PinWindowCheck.swift" \
    "${CORE_OBJECTS[@]}" -o "${PROJECT_DIR}/.build/check-pin"
"${PROJECT_DIR}/.build/check-pin"
