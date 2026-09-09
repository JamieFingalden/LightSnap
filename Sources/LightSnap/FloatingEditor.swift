import AppKit
import UniformTypeIdentifiers
import CaptureCore

@MainActor
final class EditorWindow: NSWindowController, NSWindowDelegate {
    private var canvas: AnnotationCanvas
    private var imageDocument: ImageDocument
    private var region: CaptureRegion?
    private let screen: NSScreen
    private let scroll = NSScrollView()
    private let backdrop = EditorBackdrop()
    private let toolbar = ToolStrip()
    private let stylebar = ToolStrip(height: 36)
    private var toolButtons: [ToolButton] = []
    private var colorButtons: [ToolButton] = []
    private var widthButtons: [ToolButton] = []
    private var busy = false {
        didSet {
            canvas.isExporting = busy
            updateSelectionControls()
            for view in toolbar.subviews + stylebar.subviews {
                (view as? NSControl)?.isEnabled = !busy
            }
        }
    }
    private var selectedTool = 0
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .black, .white]
    var onClose: (() -> Void)?
    var onLongCapture: ((CaptureRegion) -> Void)?
    var onPin: ((CGImage, CGRect) -> Void)?

    init(document: ImageDocument, region: CaptureRegion? = nil) {
        self.imageDocument = document
        self.region = region
        self.screen = region?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        canvas = AnnotationCanvas(document: document)
        let window = CaptureOverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init(window: window)
        window.cancelAction = { [weak self] in self?.dismiss() }
        window.title = "轻截 · 截图标注"
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.appearance = NSAppearance(named: .aqua)
        backdrop.frame = CGRect(origin: .zero, size: screen.frame.size)
        backdrop.background = region?.background
        window.contentView = backdrop
        buildTools()
        setupCanvas()
        if let region { backdrop.selection = region.rect }
        else {
            let width = min(CGFloat(document.width) / screen.backingScaleFactor, screen.frame.width - 180)
            let height = min(CGFloat(document.height) * width / CGFloat(document.width), screen.frame.height - 240)
            backdrop.selection = CGRect(x: (screen.frame.width - width) / 2, y: (screen.frame.height - height) / 2 - 30, width: width, height: height)
        }
        backdrop.resizeFinished = { [weak self] rect in self?.resizeSelection(rect) }
        backdrop.selectionChanged = { [weak self] rect in self?.previewSelection(rect) }
        backdrop.allowsMove = { [weak self] point in
            guard let self else { return false }
            return self.canvas.annotation(atViewPoint: self.canvas.convert(point, from: self.backdrop)) == nil
        }
        backdrop.resizing = { [weak self] active in
            guard let self else { return }
            self.canvas.showsImage = !active
            self.toolbar.isHidden = active
            self.stylebar.isHidden = active || self.selectedTool == 0
            if !active { self.layout() }
        }
        layout()
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档初始化") }

    private func setupCanvas() {
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = canvas
        if scroll.superview == nil { backdrop.addSubview(scroll, positioned: .below, relativeTo: toolbar) }
        canvas.changed = { [weak self] in
            guard let self else { return }
            self.updateSelectionControls()
            self.backdrop.status = ""
        }
        canvas.failed = { [weak self] error in self?.showError(error) }
        canvas.copyAction = { [weak self] in self?.copyImage() }
        canvas.saveAction = { [weak self] in self?.saveImage() }
        canvas.pinAction = { [weak self] in self?.pinImage() }
        canvas.closeAction = { [weak self] in self?.dismiss() }
    }

    private func buildTools() {
        backdrop.addSubview(toolbar)
        backdrop.addSubview(stylebar)
        let tools = [("rectangle", "矩形", 1), ("circle", "椭圆", 2), ("arrow.up.right", "箭头", 3), ("line.diagonal", "直线", 4)]
        for (symbol, label, tag) in tools {
            let button = ToolButton(symbol: symbol, label: label, target: self, action: #selector(changeTool(_:)))
            button.tag = tag
            button.chosen = tag == selectedTool
            toolButtons.append(button)
            toolbar.add(button)
        }
        toolbar.separator()
        let select = ToolButton(symbol: "cursorarrow", label: "移动选区与选择标注", target: self, action: #selector(changeTool(_:)))
        select.tag = 0
        select.chosen = selectedTool == 0
        toolButtons.append(select)
        toolbar.add(select)
        toolbar.add(ToolButton(symbol: "arrow.uturn.backward", label: "撤销 ⌘Z", target: self, action: #selector(undoEdit)))
        toolbar.add(ToolButton(symbol: "arrow.uturn.forward", label: "重做 ⇧⌘Z", target: self, action: #selector(redoEdit)))
        toolbar.separator()
        if region != nil { toolbar.add(ToolButton(symbol: "rectangle.portrait.and.arrow.forward", label: "长截图", target: self, action: #selector(startLong))) }
        toolbar.add(ToolButton(symbol: "arrow.down.to.line", label: "保存 ⌘S", target: self, action: #selector(saveImage)))
        toolbar.add(ToolButton(symbol: "pin", label: "贴图 ⌘T", target: self, action: #selector(pinImage)))
        toolbar.separator()
        toolbar.add(ToolButton(symbol: "xmark", label: "取消 Esc / 右键", target: self, action: #selector(dismiss)))
        let done = ToolButton(symbol: "checkmark", label: "完成并复制 ⌘C", target: self, action: #selector(copyImage))
        done.emphasized = true
        toolbar.add(done)
        for (index, width) in [2, 4, 8].enumerated() {
            let button = ToolButton(symbol: "circle.fill", label: "线宽 \(width)", target: self, action: #selector(changeWidth(_:)))
            button.dot = CGFloat(width)
            button.tag = width
            button.chosen = index == 1
            widthButtons.append(button)
            stylebar.add(button, width: 28)
        }
        stylebar.separator()
        for (index, color) in colors.enumerated() {
            let button = ToolButton(symbol: "square.fill", label: ["红色", "橙色", "黄色", "绿色", "蓝色", "黑色", "白色"][index], target: self, action: #selector(changeColor(_:)))
            button.swatch = color
            button.tag = index
            button.chosen = index == 0
            colorButtons.append(button)
            stylebar.add(button, width: 26)
        }
    }

    private func layout() {
        let rect = backdrop.selection
        scroll.frame = rect
        canvas.scale = rect.width / CGFloat(imageDocument.width)
        backdrop.dimensions = "\(imageDocument.width) × \(imageDocument.height) px"
        if let region {
            canvas.annotationOrigin = region.pixelRect.origin
            scroll.contentView.scroll(to: .zero)
        }
        updateSelectionControls()
        let x = max(8, min(rect.maxX - toolbar.frame.width, backdrop.bounds.width - toolbar.frame.width - 8))
        let fullHeight = toolbar.frame.height + (selectedTool == 0 ? 0 : stylebar.frame.height + 10)
        var y = rect.maxY + 9
        if y + fullHeight > backdrop.bounds.height - 8 {
            y = rect.minY - fullHeight - 9
            if y < 8 { y = max(8, backdrop.bounds.height - fullHeight - 12) }
        }
        toolbar.frame.origin = CGPoint(x: x, y: y)
        stylebar.frame.origin = CGPoint(x: x + toolbar.frame.width - stylebar.frame.width, y: y + toolbar.frame.height + 5)
        stylebar.isHidden = selectedTool == 0
        backdrop.needsDisplay = true
    }

    private func updateSelectionControls() {
        backdrop.showHandles = !busy && region != nil
        backdrop.canMoveSelection = !busy && region != nil && selectedTool == 0
    }

    private func previewSelection(_ rect: CGRect) {
        guard let region else { return }
        let pixels = CaptureRegion.pixelRect(for: rect, image: region.background, screenSize: screen.frame.size)
        scroll.frame = rect
        canvas.annotationOrigin = pixels.origin
        canvas.frame.size = rect.size
        scroll.contentView.scroll(to: .zero)
        backdrop.dimensions = "\(Int(pixels.width)) × \(Int(pixels.height)) px"
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }
    func windowWillClose(_ notification: Notification) {
        canvas.history.removeAllActions()
        scroll.documentView = nil
        window?.contentView = nil
        backdrop.background = nil
        region = nil
        onClose?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy && sender.attachedSheet == nil }
    @objc private func dismiss() {
        guard !busy, window?.attachedSheet == nil else { return }
        window?.orderOut(nil)
        close()
    }
    @objc private func changeTool(_ sender: ToolButton) {
        guard !busy else { return }
        selectedTool = sender.tag
        canvas.tool = selectedTool
        toolButtons.forEach { $0.chosen = $0.tag == selectedTool }
        layout()
        window?.makeFirstResponder(canvas)
    }
    @objc private func changeColor(_ sender: ToolButton) {
        guard !busy else { return }
        canvas.color = colors[sender.tag].cgColor
        canvas.applyStyle()
        colorButtons.forEach { $0.chosen = $0 === sender }
        window?.makeFirstResponder(canvas)
    }
    @objc private func changeWidth(_ sender: ToolButton) {
        guard !busy else { return }
        canvas.strokeWidth = CGFloat(sender.tag)
        canvas.applyStyle()
        widthButtons.forEach { $0.chosen = $0 === sender }
        window?.makeFirstResponder(canvas)
    }
    @objc private func undoEdit() { if !busy { canvas.history.undo() } }
    @objc private func redoEdit() { if !busy { canvas.history.redo() } }
    @objc private func startLong() {
        guard !busy, !backdrop.isAdjusting, let region else { return }
        dismiss()
        onLongCapture?(region)
    }

    private func resizeSelection(_ rect: CGRect) {
        guard !busy, let old = region else { backdrop.resizing?(false); return }
        guard let next = old.cropped(to: rect) else {
            backdrop.selection = old.rect
            backdrop.resizing?(false)
            return
        }
        busy = true
        Task {
            defer { busy = false; backdrop.resizing?(false) }
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    let document = try ImageDocument(width: next.image.width)
                    try document.append(next.image)
                    return document
                }.value
                imageDocument = document
                canvas.document = document
                region = next
                backdrop.selection = next.rect
                window?.makeFirstResponder(canvas)
            } catch { backdrop.selection = old.rect; showError(error) }
        }
    }

    private func showError(_ error: Error) {
        backdrop.status = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = "操作未完成"
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) }
    }
    @objc private func saveImage() {
        guard !busy, !backdrop.isAdjusting, let window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canSelectHiddenExtension = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "轻截-\(formatter.string(from: Date())).png"
        if let path = UserDefaults.standard.string(forKey: "saveDirectory") { panel.directoryURL = URL(fileURLWithPath: path) }
        busy = true
        window.orderOut(nil)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.busy = false
            self.present()
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "saveDirectory")
            self.export(to: url)
        }
    }
    @objc private func copyImage() { if !busy, !backdrop.isAdjusting { export(to: nil) } }

    @objc private func pinImage() {
        guard !busy, !backdrop.isAdjusting else { return }
        busy = true
        backdrop.status = "正在贴图…"
        let selection = backdrop.selection
        let frame = CGRect(x: screen.frame.minX + selection.minX, y: screen.frame.maxY - selection.maxY,
                           width: selection.width, height: selection.height)
        Task {
            do {
                let image = try await renderImage()
                busy = false
                dismiss()
                onPin?(image, frame)
            } catch {
                busy = false
                canvas.needsDisplay = true
                showError(error)
            }
        }
    }

    private func renderImage() async throws -> CGImage {
        let annotations = canvas.exportAnnotations
        let document = imageDocument
        return try await Task.detached(priority: .userInitiated) {
            try autoreleasepool { try document.render(annotations: annotations) }
        }.value
    }

    private func export(to url: URL?) {
        busy = true
        backdrop.status = url == nil ? "正在复制…" : "正在保存…"
        Task {
            do {
                let image = try await renderImage()
                let png = try await Task.detached(priority: .userInitiated) { () -> Data? in
                    try autoreleasepool {
                        if let url {
                            let temporary = url.deletingLastPathComponent().appendingPathComponent(".lightsnap-\(UUID().uuidString)")
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            try ImageCodec.write(image, to: temporary, jpeg: ["jpg", "jpeg"].contains(url.pathExtension.lowercased()))
                            if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
                            else { try FileManager.default.moveItem(at: temporary, to: url) }
                            return nil
                        }
                        return try ImageCodec.pngData(image)
                    }
                }.value
                if let png {
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setData(png, forType: .png) else { throw CaptureError.message("剪贴板写入失败，请重试。") }
                }
                busy = false
                dismiss()
            } catch {
                busy = false
                canvas.needsDisplay = true
                showError(error)
            }
        }
    }
}
