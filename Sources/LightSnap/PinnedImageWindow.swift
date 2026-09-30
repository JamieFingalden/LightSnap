import AppKit
import ApplicationServices
import CaptureCore

@MainActor
final class PinnedImageWindow: NSWindowController, NSWindowDelegate {
    private let image: CGImage
    private let imageSize: CGSize
    private let scroll = NSScrollView()
    private var magnification: CGFloat = 1
    private var lastGesture: TimeInterval = -1
    private var copying = false
    var onClose: (() -> Void)?

    init(image: CGImage, frame: CGRect) {
        self.image = image
        let width = max(1, frame.width - 2)
        imageSize = CGSize(width: width, height: CGFloat(image.height) * width / CGFloat(image.width))
        let window = CaptureOverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "轻截 · 贴图"
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self

        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.borderColor = SnapStyle.accent.withAlphaComponent(0.7).cgColor
        content.layer?.borderWidth = 1
        window.contentView = content
        scroll.frame = content.bounds.insetBy(dx: 1, dy: 1)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        content.addSubview(scroll)

        let imageView = PinnedImageView(frame: CGRect(origin: .zero, size: imageSize))
        imageView.image = NSImage(cgImage: image, size: imageView.bounds.size)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTopLeft
        imageView.toolTip = "拖动移动 · 双击关闭 · 右键打开菜单 · 滚轮、捏合或 ⌘+ / ⌘− 缩放 · ⌘0 恢复 · 双指滚动查看长图"
        imageView.setAccessibilityLabel("贴图预览")
        imageView.copyAction = { [weak self] in self?.copyImage() }
        imageView.closeAction = { [weak self] in self?.close() }
        imageView.zoomAction = { [weak self] factor in self?.zoom(by: factor) }
        imageView.resetAction = { [weak self] in self?.resetZoom() }
        imageView.magnifyAction = { [weak self] event in self?.handleMagnify(event) }
        imageView.scrollAction = { [weak self] event in self?.zoom(scrolling: event) ?? false }
        scroll.documentView = imageView

        let menu = NSMenu()
        for (title, action) in [("复制贴图", #selector(copyImage)), ("恢复缩放", #selector(resetZoom)), ("关闭该贴图", #selector(closePin))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        imageView.menu = menu
        fitWindowToImage(anchor: zoomAnchor())
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档初始化") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(scroll.documentView)
        PinGestureTap.register(self)
    }

    func windowWillClose(_ notification: Notification) {
        PinGestureTap.unregister(self)
        scroll.documentView = nil
        window?.contentView = nil
        onClose?()
    }

    /// 捏合事件可能同时由 AppKit 分发和事件 tap 转发送达，按时间戳去重。
    func handleMagnify(_ event: NSEvent) {
        guard event.timestamp != lastGesture else { return }
        lastGesture = event.timestamp
        zoom(by: 1 + event.magnification)
    }

    /// 鼠标滚轮直接缩放；触控板和 Magic Mouse 的双指滚动保留给长图，按住 ⌘ 时缩放。鼠标按住 ⌥ 改为滚动长图。
    /// 返回 false 表示交给滚动视图处理。
    private func zoom(scrolling event: NSEvent) -> Bool {
        let wheel = !event.hasPreciseScrollingDeltas
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || (wheel && !flags.contains(.option)) else { return false }
        guard event.momentumPhase.isEmpty, event.scrollingDeltaY != 0 else { return true }
        // 统一按设备方向：向前推滚轮或双指向上为放大，不受「自然滚动」设置影响。
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        zoom(by: wheel ? pow(1.12, max(-5, min(5, delta))) : pow(1.005, max(-80, min(80, delta))))
        return true
    }

    private func zoom(by factor: CGFloat) {
        let target = min(5, max(0.1, magnification * factor))
        guard target != magnification else { return }
        magnification = target
        fitWindowToImage(anchor: zoomAnchor())
    }

    /// 以光标位置为缩放中心；光标不在贴图上时以窗口中心为准。
    private func zoomAnchor() -> CGPoint {
        guard let frame = window?.frame else { return .zero }
        let mouse = NSEvent.mouseLocation
        return frame.contains(mouse) ? mouse : CGPoint(x: frame.midX, y: frame.midY)
    }

    private func fitWindowToImage(anchor rawAnchor: CGPoint) {
        guard let window, let imageView = scroll.documentView,
              let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        // 系统会把窗口 frame 对齐到整点；若请求的是分数尺寸，回读到的 frame 与请求不一致，
        // 误差会随逐事件重算的锚点回灌累积成漂移。这里锚点、图片、窗口全部取整，
        // 让「请求的 frame」就是「实际的 frame」，漂移在数学上归零。
        let anchor = CGPoint(x: rawAnchor.x.rounded(), y: rawAnchor.y.rounded())
        let frame = window.frame
        let offset = scroll.contentView.bounds.origin
        let old = imageView.frame.size
        // 记录锚点落在图片上的相对位置（图片坐标向下为正），缩放后让同一点仍留在锚点下。
        let fx = min(1, max(0, (anchor.x - frame.minX - 1 + offset.x) / max(1, old.width)))
        let fy = min(1, max(0, (frame.maxY - 1 - anchor.y + offset.y) / max(1, old.height)))
        // 图片尺寸量化到偶数：中心锚点恒为整数点、fx 恒等于 1/2，奇偶交替产生的 ±0.5 取整偏向随之消失。
        let scaled = CGSize(width: (imageSize.width * magnification / 2).rounded() * 2,
                            height: (imageSize.height * magnification / 2).rounded() * 2)
        let size = CGSize(width: min(scaled.width + 2, visible.width.rounded(.down)),
                          height: min(scaled.height + 2, visible.height.rounded(.down)))
        // 窗口贴合图片；超出屏幕的长图限制在可用范围内，剩余部分靠滚动查看。
        let minX = max(visible.minX.rounded(.up), min((anchor.x - fx * scaled.width - 1).rounded(), (visible.maxX - size.width).rounded(.down)))
        let maxY = max(visible.minY.rounded(.up) + size.height, min((anchor.y + fy * scaled.height + 1).rounded(), visible.maxY.rounded(.down)))
        imageView.setFrameSize(scaled)
        window.setFrame(CGRect(x: minX, y: maxY - size.height, width: size.width, height: size.height), display: true)
        let origin = CGPoint(x: min(max(0, fx * scaled.width - (anchor.x - minX - 1)), max(0, scaled.width - size.width + 2)),
                             y: min(max(0, fy * scaled.height - (maxY - 1 - anchor.y)), max(0, scaled.height - size.height + 2)))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func resetZoom() {
        magnification = 1
        fitWindowToImage(anchor: zoomAnchor())
        scroll.documentView?.scroll(.zero)
    }
    @objc private func closePin() { close() }

    @objc private func copyImage() {
        guard !copying else { return }
        copying = true
        let image = image
        Task {
            defer { copying = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try autoreleasepool { try ImageCodec.pngData(image) }
                }.value
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setData(data, forType: .png) else { throw CaptureError.message("剪贴板写入失败，请重试。") }
            } catch {
                guard let window, window.isVisible else { return }
                let alert = NSAlert()
                alert.messageText = "贴图复制未完成"
                alert.informativeText = error.localizedDescription
                await alert.beginSheetModal(for: window)
            }
        }
    }
}

/// macOS 只把触控板捏合发给前台应用，而贴图是不激活轻截的面板，捏合手势不会送到贴图。
/// 在已授予辅助功能（或输入监控）权限时，用只读事件 tap 观察手势，把落在贴图上的捏合转发给对应窗口；
/// 没有权限时系统会抹掉手势数据，安装没有意义，这里也不主动弹出授权请求。
@MainActor
enum PinGestureTap {
    private struct Entry { weak var pin: PinnedImageWindow? }
    private static var pins: [Entry] = []
    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?

    static var isActive: Bool { tap != nil }

    static func register(_ pin: PinnedImageWindow) {
        pins.removeAll { $0.pin == nil || $0.pin === pin }
        pins.append(Entry(pin: pin))
        install()
    }

    static func unregister(_ pin: PinnedImageWindow) {
        pins.removeAll { $0.pin == nil || $0.pin === pin }
        if pins.isEmpty { remove() }
    }

    /// 可重复调用：用户在系统设置里开启权限后，下一次贴图或点击贴图时生效。
    static func install() {
        guard tap == nil, !pins.isEmpty, CGPreflightListenEventAccess() || AXIsProcessTrusted() else { return }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = PinGestureTap.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if let gesture = NSEvent(cgEvent: event), gesture.type == .magnify {
                    PinGestureTap.route(gesture)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        // 触控板手势的 CGEvent 类型统一为 NSEvent.EventType.gesture，转换成 NSEvent 后再区分捏合。
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: CGEventMask(NSEvent.EventTypeMask.gesture.rawValue),
                                           callback: callback, userInfo: nil) else { return }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = runLoopSource
    }

    private static func remove() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        tap = nil
        source = nil
    }

    static func route(_ event: NSEvent) {
        // 手势发生在光标位置。系统的窗口命中会被 Dock 等全屏透明窗口干扰，这里只在贴图之间按层序取最上面一张。
        let location = NSEvent.mouseLocation
        let hit = pins.compactMap(\.pin).filter { $0.window?.isVisible == true && $0.window?.frame.contains(location) == true }
        hit.min { ($0.window?.orderedIndex ?? .max) < ($1.window?.orderedIndex ?? .max) }?.handleMagnify(event)
    }
}

private final class PinnedImageView: NSImageView {
    var copyAction: (() -> Void)?
    var closeAction: (() -> Void)?
    var zoomAction: ((CGFloat) -> Void)?
    var resetAction: (() -> Void)?
    var magnifyAction: ((NSEvent) -> Void)?
    var scrollAction: ((NSEvent) -> Bool)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        PinGestureTap.install()
        if event.clickCount == 2 { closeAction?() }
        else { window?.performDrag(with: event) }
    }

    override func magnify(with event: NSEvent) { magnifyAction?(event) }

    override func scrollWheel(with event: NSEvent) {
        if scrollAction?(event) != true { super.scrollWheel(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copyAction?(); return true
            case "w": closeAction?(); return true
            case "+", "=": zoomAction?(1.2); return true
            case "-": zoomAction?(1 / 1.2); return true
            case "0": resetAction?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closeAction?() }
        else { super.keyDown(with: event) }
    }
}
