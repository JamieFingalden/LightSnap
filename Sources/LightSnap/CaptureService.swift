import AppKit
import ScreenCaptureKit
import CaptureCore

struct ScreenShot {
    let screen: NSScreen
    let display: SCDisplay
    let image: CGImage
}

struct CaptureRegion {
    let screen: NSScreen
    let display: SCDisplay
    let rect: CGRect
    let image: CGImage
    let background: CGImage

    var screenRect: CGRect {
        CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }
}

@MainActor
enum CaptureService {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    static func filter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
    }

    static func configuration(display: SCDisplay, screen: NSScreen, rect: CGRect? = nil) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let bounds = rect ?? CGRect(origin: .zero, size: screen.frame.size)
        config.sourceRect = bounds
        config.width = Int((bounds.width * screen.backingScaleFactor).rounded())
        config.height = Int((bounds.height * screen.backingScaleFactor).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    static func screens() async throws -> [ScreenShot] {
        let content = try await content()
        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter(display: display, content: content),
                configuration: configuration(display: display, screen: screen))
            shots.append(ScreenShot(screen: screen, display: display, image: image))
        }
        guard !shots.isEmpty else { throw CaptureError.message("没有找到可截图的显示器。") }
        return shots
    }

    static func window(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        config.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var onFinish: ((CaptureRegion?) -> Void)?

    func show(shots: [ScreenShot], long: Bool, completion: @escaping (CaptureRegion?) -> Void) {
        onFinish = completion
        for shot in shots {
            let window = CaptureOverlayWindow(contentRect: shot.screen.frame, styleMask: .borderless,
                                              backing: .buffered, defer: false)
            window.level = .screenSaver
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(shot: shot, long: long)
            view.finished = { [weak self] rect in
                guard let self else { return }
                var region: CaptureRegion?
                if let rect {
                    let sx = CGFloat(shot.image.width) / shot.screen.frame.width
                    let sy = CGFloat(shot.image.height) / shot.screen.frame.height
                    let pixels = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy).integral
                    if let image = shot.image.cropping(to: pixels) {
                        region = CaptureRegion(screen: shot.screen, display: shot.display, rect: rect, image: image, background: shot.image)
                    }
                }
                self.finish(region)
            }
            window.contentView = view
            windows.append(window)
            window.orderFrontRegardless()
            if shot.screen.frame.contains(NSEvent.mouseLocation) {
                window.makeKey()
                window.makeFirstResponder(view)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() { finish(nil) }

    private func finish(_ region: CaptureRegion?) {
        for window in windows { window.orderOut(nil); window.contentView = nil; window.close() }
        windows.removeAll()
        let callback = onFinish
        onFinish = nil
        callback?(region)
    }
}

private final class SelectionView: NSView {
    let shot: ScreenShot
    let long: Bool
    var finished: ((CGRect?) -> Void)?
    var anchor: CGPoint?
    var selection = CGRect.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(shot: ScreenShot, long: Bool) {
        self.shot = shot
        self.long = long
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        setAccessibilityLabel("拖动框选截图区域，Escape 取消")
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档初始化") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(shot.image, in: bounds)
        context.restoreGState()
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.42).setFill()
        shade.fill()
        if !selection.isEmpty {
            SnapStyle.accent.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 1.5
            outline.stroke()
        }
        let scale = shot.screen.backingScaleFactor
        let text = selection.isEmpty
            ? (long ? "框选滚动内容区 · 避开固定栏和滚动条 · Esc 取消" : "拖动选择区域 · 双击截取当前屏幕 · Esc 取消")
            : "\(Int(selection.width * scale)) × \(Int(selection.height * scale)) px · 松开确认"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let x = selection.isEmpty ? (bounds.width - size.width - 14) / 2 : min(selection.minX, bounds.width - size.width - 20)
        let y = selection.isEmpty ? 52 : max(6, selection.minY - 28)
        let box = CGRect(x: max(6, x), y: y, width: size.width + 14, height: 21)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 7, y: box.minY + 4), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount == 2, !long { finished?(bounds); return }
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds).integral
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if selection.width >= (long ? 100 : 3), selection.height >= (long ? 100 : 3) { finished?(selection) }
        else { anchor = nil; selection = .zero; needsDisplay = true }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finished?(nil) } else { super.keyDown(with: event) }
    }
}
