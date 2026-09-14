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

    var pixelRect: CGRect { Self.pixelRect(for: rect, image: background, screenSize: screen.frame.size) }

    static func pixelRect(for rect: CGRect, image: CGImage, screenSize: CGSize) -> CGRect {
        let sx = CGFloat(image.width) / screenSize.width
        let sy = CGFloat(image.height) / screenSize.height
        return CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy).integral
    }

    func cropped(to rect: CGRect) -> CaptureRegion? {
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let rect = rect.intersection(bounds).integral.intersection(bounds)
        guard rect.width >= 3, rect.height >= 3,
              let image = background.cropping(to: Self.pixelRect(for: rect, image: background, screenSize: screen.frame.size)) else { return nil }
        return CaptureRegion(screen: screen, display: display, rect: rect, image: image, background: background)
    }

    var screenRect: CGRect {
        CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }
}

@MainActor
enum CaptureService {
    static func content(excludingDesktopWindows: Bool = true) async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(excludingDesktopWindows, onScreenWindowsOnly: true)
    }

    static func filter(display: SCDisplay, content: SCShareableContent, excludingWindows: [SCWindow] = []) -> SCContentFilter {
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: excludingWindows)
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

final class CaptureOverlayWindow: NSPanel {
    var cancelAction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        // 截图与贴图只接收键盘焦点，不激活轻截，避免让原应用退到后台或切换桌面。
        super.init(contentRect: contentRect, styleMask: style.union(.nonactivatingPanel), backing: backingStoreType, defer: flag)
        hidesOnDeactivate = false
    }

    override func sendEvent(_ event: NSEvent) {
        if attachedSheet == nil, let cancelAction,
           event.type == .rightMouseDown || (event.type == .keyDown && event.keyCode == 53)
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            // 双指辅助点按由 macOS 发送右键事件；统一处理整个浮层，避免画布或工具栏截获。
            cancelAction()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var onFinish: ((CaptureRegion?) -> Void)?

    func show(shots: [ScreenShot], long: Bool, completion: @escaping (CaptureRegion?) -> Void) {
        onFinish = completion
        let candidates = SelectionWindow.snapshot()
        for shot in shots {
            let window = CaptureOverlayWindow(contentRect: shot.screen.frame, styleMask: .borderless,
                                              backing: .buffered, defer: false)
            window.level = .screenSaver
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(image: shot.image, displayFrame: CGDisplayBounds(shot.display.displayID), candidates: candidates, long: long)
            window.cancelAction = { [weak view] in view?.cancelOperation(nil) }
            view.finished = { [weak self] rect in
                guard let self else { return }
                var region: CaptureRegion?
                if let rect {
                    let pixels = CaptureRegion.pixelRect(for: rect, image: shot.image, screenSize: shot.screen.frame.size)
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
                view.preview(at: view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
            }
        }
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

final class SelectionView: NSView {
    let image: CGImage
    let displayFrame: CGRect
    let candidates: [SelectionWindow]
    let long: Bool
    var finished: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var dragging = false
    private var confirming = false
    private var hoverPoint: CGPoint?
    private var hoveredWindow: SelectionWindow?
    private let locator = ElementLocator()
    private var tracking: NSTrackingArea?
    private(set) var selection = CGRect.zero
    private var minimumSize: CGFloat { long ? 100 : 3 }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage, displayFrame: CGRect, candidates: [SelectionWindow], long: Bool) {
        self.image = image
        self.displayFrame = displayFrame
        self.candidates = candidates
        self.long = long
        super.init(frame: CGRect(origin: .zero, size: displayFrame.size))
        setAccessibilityLabel("悬停定位，单击选中截图区域，拖动手动框选，Escape 或右键取消")
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档初始化") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { locator.cancel() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func localRect(_ frame: CGRect) -> CGRect {
        let clipped = frame.intersection(displayFrame)
        guard !clipped.isNull else { return .zero }
        return clipped.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY).integral.intersection(bounds)
    }

    func preview(at point: CGPoint) {
        guard anchor == nil, !confirming, bounds.contains(point) else { return }
        hoverPoint = point
        let global = CGPoint(x: displayFrame.minX + point.x, y: displayFrame.minY + point.y)
        let target = candidates.first { $0.frame.contains(global) }
        let fallback = target.map { localRect($0.frame) } ?? bounds
        // 同一窗口内等待控件结果时保留原选区，避免先放大到窗口再缩回控件造成遮罩闪烁。
        if target != hoveredWindow || selection.isEmpty {
            if selection != fallback { selection = fallback; needsDisplay = true }
        }
        hoveredWindow = target
        guard let target else { locator.cancel(); return }
        locator.locate(at: global, in: target, minimumSize: minimumSize) { [weak self] frame in
            self?.applyHoverResult(frame, in: target, at: point)
        }
    }

    func applyHoverResult(_ frame: CGRect?, in target: SelectionWindow, at point: CGPoint) {
        guard anchor == nil, !confirming, hoveredWindow == target,
              let current = hoverPoint, let frame else { return }
        let rect = localRect(frame)
        // 过期的窗口结果不能覆盖新位置的控件选区；暂时读取失败也保留已有预览。
        guard rect.contains(current), current == point || rect != localRect(target.frame),
              rect.width >= minimumSize, rect.height >= minimumSize, rect != selection else { return }
        selection = rect
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { preview(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        guard anchor == nil, !confirming else { return }
        locator.cancel()
        hoverPoint = nil
        hoveredWindow = nil
        selection = .zero
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
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
        let hint = dragging ? "松开确认 · Esc / 右键取消"
            : (long ? "单击选中 · 拖动框选滚动内容区 · Esc / 右键取消" : "单击选中 · 拖动框选 · 空格全屏 · Esc / 右键取消")
        let text = selection.isEmpty ? hint
            : "\(Int(selection.width * CGFloat(image.width) / bounds.width)) × \(Int(selection.height * CGFloat(image.height) / bounds.height)) px · \(hint)"
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
        guard !confirming else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        preview(at: point)
        locator.cancel()
        anchor = point
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        updateDrag(to: convert(event.locationInWindow, from: nil))
    }
    private func updateDrag(to point: CGPoint) {
        guard let anchor else { return }
        guard dragging || hypot(point.x - anchor.x, point.y - anchor.y) >= 3 else { return }
        dragging = true
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds).integral
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateDrag(to: point)
        anchor = nil
        let manual = dragging
        dragging = false
        if !manual, let target = hoveredWindow {
            // 单击时等最终命中结果，避免首次悬停尚未完成就把整个窗口截下来。
            confirming = true
            let global = CGPoint(x: displayFrame.minX + point.x, y: displayFrame.minY + point.y)
            locator.locate(at: global, in: target, minimumSize: minimumSize) { [weak self] frame in
                guard let self, self.confirming else { return }
                self.confirming = false
                // 单击确认不能沿用等待期间保留的旧控件，读取失败时明确使用当前窗口。
                self.selection = self.localRect(frame ?? target.frame)
                self.confirmSelection(at: point)
            }
        } else { confirmSelection(at: point) }
    }

    private func confirmSelection(at point: CGPoint) {
        if selection.width >= minimumSize, selection.height >= minimumSize { locator.cancel(); finished?(selection) }
        else { selection = .zero; preview(at: point); needsDisplay = true }
    }

    override func cancelOperation(_ sender: Any?) {
        locator.cancel()
        confirming = false
        anchor = nil
        dragging = false
        finished?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else if event.keyCode == 49, !long { locator.cancel(); finished?(bounds) }
        else { super.keyDown(with: event) }
    }
}
