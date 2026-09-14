import AppKit
import CaptureCore
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotKeys()
    private let recording = RecordingController()
    private var selector: RegionSelector?
    private var editor: EditorWindow?
    private var pins: [PinnedImageWindow] = []
    private var longCapture: LongCapture?
    private var welcome: NSWindow?
    private var settings: SettingsWindow?
    private var capturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        recording.stateChanged = { [weak self] in self?.updateRecordingStatus() }
        recording.canStart = { [weak self] in
            guard let self, self.prepareCapture() else { return false }
            self.capturing = false
            return true
        }
        hotkeys.action = { [weak self] id in
            if id == 3 { self?.recordScreen() }
            else if id == 4 { self?.recording.togglePause() }
            else if self?.longCapture != nil { self?.longCapture?.finishCapture() }
            else { self?.capture(long: id == 2) }
        }
        let registered = hotkeys.register()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--open-recording"), arguments.indices.contains(index + 1) {
            do { recording.open(try RecordingDocument.open(URL(fileURLWithPath: arguments[index + 1]))) }
            catch { showError(error) }
        }
        else if arguments.contains("--recording") { recording.presentSetup() }
        else if arguments.contains("--demo") { demo() }
        else { showWelcome() }
        if !registered { showError(CaptureError.message("部分快捷键被其他应用占用，可在设置中更换；菜单截图仍可使用。")) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if recording.isBusy || recording.phase == .preview { recording.present(); return true }
        guard !hasVisibleWindows, !capturing, editor == nil, longCapture == nil else { return true }
        if CommandLine.arguments.contains("--demo") { demo() }
        else { showWelcome() }
        return true
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "轻截")
        statusItem.button?.toolTip = "轻截 · 截图与标注"
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [("区域截图", #selector(regionCapture)), ("窗口截图…", #selector(windowCapture)), ("当前屏幕截图", #selector(screenCapture)), ("长截图", #selector(scrollCapture))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (index, entry) in [("录屏…", #selector(recordScreen)), ("暂停录屏", #selector(pauseRecording)), ("打开已有录屏…", #selector(openRecording)), ("录屏文件夹", #selector(showRecordings))].enumerated() {
            let item = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: "")
            item.target = self
            item.tag = 30 + index
            item.isEnabled = index != 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [("使用说明", #selector(showWelcome)), ("设置…", #selector(showSettings)), ("退出轻截", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出轻截", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)
        let recordingItem = NSMenuItem(title: "录屏", action: nil, keyEquivalent: "")
        let recordingMenu = NSMenu(title: "录屏")
        recordingMenu.addItem(withTitle: "新建录屏…", action: #selector(recordScreen), keyEquivalent: "").target = self
        recordingMenu.addItem(withTitle: "打开已有录屏…", action: #selector(openRecording), keyEquivalent: "o").target = self
        recordingMenu.addItem(withTitle: "录屏文件夹", action: #selector(showRecordings), keyEquivalent: "").target = self
        recordingItem.submenu = recordingMenu
        main.addItem(recordingItem)
        let editItem = NSMenuItem()
        editItem.title = "编辑"
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func regionCapture() { capture(long: false) }
    @objc private func scrollCapture() { capture(long: true) }

    @objc private func recordScreen() {
        if recording.isRecording { recording.stop(); return }
        if recording.isBusy { recording.present(); return }
        guard prepareCapture() else { return }
        capturing = false
        recording.presentSetup()
    }
    @objc private func pauseRecording() { recording.togglePause() }
    @objc private func openRecording() {
        guard !capturing, longCapture == nil else { return }
        recording.openDialog()
    }
    @objc private func showRecordings() {
        do {
            try FileManager.default.createDirectory(at: RecordingDocument.libraryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(RecordingDocument.libraryURL)
        } catch { showError(error) }
    }
    private func updateRecordingStatus() {
        let active = recording.isRecording
        statusItem.length = active ? NSStatusItem.variableLength : NSStatusItem.squareLength
        statusItem.button?.image = NSImage(systemSymbolName: active ? "record.circle.fill" : "viewfinder", accessibilityDescription: active ? "正在录屏" : "轻截")
        statusItem.button?.contentTintColor = active ? (recording.phase == .paused ? .systemOrange : .systemRed) : nil
        statusItem.button?.title = active ? " \(recording.statusTitle)" : ""
        statusItem.button?.toolTip = active ? "轻截 · \(recording.phase == .paused ? "录屏已暂停" : "正在录屏")" : "轻截 · 截图与录屏"
        statusItem.menu?.item(withTag: 30)?.title = active ? "结束录屏" : "录屏…"
        statusItem.menu?.item(withTag: 31)?.title = recording.phase == .paused ? "继续录屏" : "暂停录屏"
        statusItem.menu?.item(withTag: 31)?.isEnabled = active
        statusItem.menu?.item(withTag: 32)?.isEnabled = !recording.isBusy
    }

    private func prepareCapture() -> Bool {
        guard !capturing, longCapture == nil, !recording.isBusy else { NSSound.beep(); return false }
        if let editor {
            editor.window?.performClose(nil)
            if self.editor != nil { return false }
        }
        welcome?.orderOut(nil)
        settings?.window?.orderOut(nil)
        capturing = true
        return true
    }

    func capture(long: Bool) {
        let previousApp = NSWorkspace.shared.frontmostApplication
        guard prepareCapture() else { return }
        Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let shots = try await CaptureService.screens()
                let selector = RegionSelector()
                self.selector = selector
                selector.show(shots: shots, long: long) { [weak self] region in
                    guard let self else { return }
                    self.selector = nil
                    self.capturing = false
                    guard let region else { previousApp?.activate(); return }
                    if long {
                        previousApp?.activate()
                        self.startLong(region)
                    } else { self.openImage(region.image, region: region) }
                }
            } catch { capturing = false; captureError(error) }
        }
    }

    private func startLong(_ region: CaptureRegion) {
        let session = LongCapture()
        longCapture = session
        session.completed = { [weak self] document in
            guard let self else { return }
            self.longCapture = nil
            if let document { self.openDocument(document) }
        }
        Task {
            do { try await session.start(region: region) }
            catch { longCapture = nil; captureError(error) }
        }
    }

    @objc private func screenCapture() {
        guard prepareCapture() else { return }
        Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let shots = try await CaptureService.screens()
                capturing = false
                if let shot = shots.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) ?? shots.first { openImage(shot.image) }
            } catch { capturing = false; captureError(error) }
        }
    }

    @objc private func windowCapture() {
        guard prepareCapture() else { return }
        Task {
            do {
                let content = try await CaptureService.content()
                let windows = content.windows.filter { $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 80 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
                guard !windows.isEmpty else { throw CaptureError.message("没有找到可截图的窗口。") }
                let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 420, height: 28))
                for window in windows { picker.addItem(withTitle: "\(window.owningApplication?.applicationName ?? "应用") · \(window.title?.isEmpty == false ? window.title! : "未命名窗口")") }
                let alert = NSAlert()
                alert.messageText = "选择截图窗口"
                alert.accessoryView = picker
                alert.addButton(withTitle: "截图")
                alert.addButton(withTitle: "取消")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { capturing = false; return }
                let image = try await CaptureService.window(windows[picker.indexOfSelectedItem])
                openImage(image)
            } catch { capturing = false; captureError(error) }
        }
    }

    private func openImage(_ image: CGImage, region: CaptureRegion? = nil) {
        capturing = true
        Task {
            defer { capturing = false }
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    let document = try ImageDocument(width: image.width)
                    try document.append(image)
                    return document
                }.value
                openDocument(document, region: region)
            } catch { showError(error) }
        }
    }
    private func openDocument(_ document: ImageDocument, region: CaptureRegion? = nil) {
        let controller = EditorWindow(document: document, region: region)
        controller.onClose = { [weak self] in self?.editor = nil }
        controller.onLongCapture = { [weak self] region in self?.startLong(region) }
        controller.onPin = { [weak self] image, frame in self?.openPin(image, frame: frame) }
        editor = controller
        controller.present()
    }

    private func openPin(_ image: CGImage, frame: CGRect) {
        let controller = PinnedImageWindow(image: image, frame: frame)
        controller.onClose = { [weak self, weak controller] in
            self?.pins.removeAll { $0 === controller }
        }
        pins.append(controller)
        controller.present()
    }

    private func captureError(_ error: Error) {
        let systemError = error as NSError
        NSLog("截图失败：%@（%@，%ld）", systemError.localizedDescription, systemError.domain, systemError.code)
        if systemError.domain == SCStreamError.errorDomain && systemError.code == SCStreamError.Code.userDeclined.rawValue {
            let alert = NSAlert()
            alert.messageText = "系统未允许本次截图"
            alert.informativeText = "macOS 拒绝了轻截的屏幕录制请求。\n\n如果已经开启权限且重启无效，请在系统设置中删除旧的「轻截」条目，再添加当前应用并开启权限，然后退出并重新打开。\n\n当前应用：\(Bundle.main.bundleURL.path)\n系统错误：\(systemError.domain)（\(systemError.code)）"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "退出轻截")
            alert.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            case .alertSecondButtonReturn:
                quit()
            default:
                break
            }
        } else {
            showError(CaptureError.message("\(systemError.localizedDescription)\n\n系统错误：\(systemError.domain)（\(systemError.code)）"))
        }
    }
    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "轻截未能完成操作"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func showWelcome() {
        if welcome == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 510, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "轻截 LightSnap"
            window.isReleasedWhenClosed = false
            window.center()
            let title = NSTextField(labelWithString: "截图，画两笔，发出去。")
            title.font = .systemFont(ofSize: 25, weight: .semibold)
            let subtitle = NSTextField(wrappingLabelWithString: "截图、标注、长截图和桌面贴图。\n使用后关闭编辑窗口，轻截会留在菜单栏。")
            subtitle.textColor = .secondaryLabelColor
            let capture = NSButton(title: "开始截图", target: self, action: #selector(regionCapture))
            capture.bezelColor = .systemTeal
            let long = NSButton(title: "开始长截图", target: self, action: #selector(scrollCapture))
            let record = NSButton(title: "开始录屏", target: self, action: #selector(recordScreen))
            let buttons = NSStackView(views: [capture, long, record])
            buttons.spacing = 12
            let detail = NSTextField(wrappingLabelWithString: "默认快捷键：⌃1 截图，⌃2 长截图\n长截图：框选内容区，手动缓慢向下滚动；再次按快捷键完成。\n标注后按 ⌘T 贴图、⌘C 复制、⌘S 保存、⌘Z 撤销。")
            detail.font = .systemFont(ofSize: 12)
            let settings = NSButton(title: "快捷键与启动设置…", target: self, action: #selector(showSettings))
            let stack = NSStackView(views: [title, subtitle, buttons, detail, settings])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 22
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(stack)
            if let content = window.contentView {
                NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28)])
            }
            welcome = window
        }
        NSApp.activate(ignoringOtherApps: true)
        welcome?.makeKeyAndOrderFront(nil)
    }
    @objc private func showSettings() {
        if settings == nil {
            let settings = SettingsWindow()
            settings.changed = { [weak self] in self?.hotkeys.register() ?? false }
            self.settings = settings
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
    }
    @objc private func quit() {
        guard recording.prepareToQuit() else { return }
        if longCapture != nil { longCapture?.finishCapture(); return }
        if let editor { editor.window?.performClose(nil); if self.editor != nil { return } }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        recording.prepareToQuit() ? .terminateNow : .terminateCancel
    }

    private func demo() {
        let image = NSImage(size: CGSize(width: 1500, height: 1000))
        image.lockFocus()
        NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.96, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 1500, height: 1000).fill()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 52, weight: .semibold), .foregroundColor: NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.3, alpha: 1)]
        ("轻截 · 标注试用画布" as NSString).draw(at: CGPoint(x: 90, y: 840), withAttributes: title)
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.darkGray]
        ("这是一张内置测试图片，不是你的屏幕截图。" as NSString).draw(at: CGPoint(x: 90, y: 780), withAttributes: text)
        for (index, name) in ["01   框选重点", "02   画箭头", "03   复制或保存"].enumerated() {
            let rect = CGRect(x: 90 + index * 450, y: 390, width: 410, height: 290)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).fill()
            (name as NSString).draw(at: CGPoint(x: rect.minX + 28, y: rect.maxY - 70), withAttributes: text)
            NSColor.systemTeal.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 28, dy: 95), xRadius: 10, yRadius: 10).fill()
        }
        ("选中图形边缘可以移动 · Delete 删除 · ⌘Z 撤销" as NSString).draw(at: CGPoint(x: 90, y: 260), withAttributes: text)
        image.unlockFocus()
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { openImage(cg) }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
