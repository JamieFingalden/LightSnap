import AppKit
import CaptureCore

@MainActor
final class PinnedImageWindow: NSWindowController, NSWindowDelegate {
    private let image: CGImage
    private let imageSize: CGSize
    private let scroll = NSScrollView()
    private var magnification: CGFloat = 1
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
        imageView.toolTip = "拖动移动 · 双击关闭 · 右键打开菜单 · 双指或 ⌘+ / ⌘− 缩放 · 滚动查看长图"
        imageView.setAccessibilityLabel("贴图预览")
        imageView.copyAction = { [weak self] in self?.copyImage() }
        imageView.closeAction = { [weak self] in self?.close() }
        imageView.zoomAction = { [weak self] factor in self?.zoom(by: factor) }
        imageView.resetAction = { [weak self] in self?.resetZoom() }
        scroll.documentView = imageView

        let menu = NSMenu()
        for (title, action) in [("复制贴图", #selector(copyImage)), ("恢复缩放", #selector(resetZoom)), ("关闭该贴图", #selector(closePin))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        imageView.menu = menu
        fitWindowToImage()
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档初始化") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(scroll.documentView)
    }

    func windowWillClose(_ notification: Notification) {
        scroll.documentView = nil
        window?.contentView = nil
        onClose?()
    }

    private func zoom(by factor: CGFloat) {
        magnification = min(5, max(0.1, magnification * factor))
        fitWindowToImage()
    }

    private func fitWindowToImage() {
        guard let window, let imageView = scroll.documentView,
              let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let scaledSize = CGSize(width: imageSize.width * magnification, height: imageSize.height * magnification)
        imageView.setFrameSize(scaledSize)
        let size = CGSize(width: min(ceil(scaledSize.width) + 2, visibleFrame.width),
                          height: min(ceil(scaledSize.height) + 2, visibleFrame.height))
        // 缩放时让窗口贴合图片；超出屏幕的长图保留滚动查看。
        let origin = CGPoint(x: max(visibleFrame.minX, min(window.frame.minX, visibleFrame.maxX - size.width)),
                             y: max(visibleFrame.minY, min(window.frame.maxY - size.height, visibleFrame.maxY - size.height)))
        window.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    @objc private func resetZoom() {
        magnification = 1
        fitWindowToImage()
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

private final class PinnedImageView: NSImageView {
    var copyAction: (() -> Void)?
    var closeAction: (() -> Void)?
    var zoomAction: ((CGFloat) -> Void)?
    var resetAction: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { closeAction?() }
        else { window?.performDrag(with: event) }
    }

    override func magnify(with event: NSEvent) { zoomAction?(1 + event.magnification) }

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
