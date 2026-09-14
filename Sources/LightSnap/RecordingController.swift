import AppKit
import AVKit
import SwiftUI
import ScreenCaptureKit
import ApplicationServices
import CaptureCore

@MainActor
final class RecordingController: NSObject, ObservableObject, NSWindowDelegate {
    enum Phase { case idle, choosing, countdown, preparing, recording, paused, finishing, preview, exporting }
    @Published var phase = Phase.idle { didSet { stateChanged?() } }
    @Published var options = RecordingOptions()
    @Published var style = RecordingStyle()
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var cameras: [AVCaptureDevice] = []
    @Published var microphones: [AVCaptureDevice] = []
    @Published var displayID: CGDirectDisplayID = 0
    @Published var windowID: CGWindowID = 0
    @Published var sourceImage: NSImage?
    @Published var loading = false
    @Published var rebuilding = false
    @Published var error: String?
    @Published var message = ""
    @Published var seconds = 0.0
    @Published var position = 0.0
    @Published var countdown = 3
    @Published var isPlaying = false
    @Published var exportProgress = 0.0
    @Published var lastExport: URL?
    @Published private(set) var document: RecordingDocument?
    let player = AVPlayer()
    var canStart: (() -> Bool)?
    var stateChanged: (() -> Void)?
    private(set) var permissionPane: String?
    var cameraSession: AVCaptureSession? { options.cameraID.isEmpty ? nil : capture?.cameraSession }
    var isBusy: Bool { ![Phase.idle, .preview].contains(phase) }
    var isRecording: Bool { phase == .recording || phase == .paused }
    var hasSource: Bool {
        switch options.sourceKind {
        case 0, 2: return !displays.isEmpty
        case 1: return !windows.isEmpty
        default: return false
        }
    }
    var statusTitle: String { isRecording ? Self.timeLabel(seconds) : "" }
    private var setupWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var hud: NSPanel?
    private var border: NSWindow?
    private var selector: RegionSelector?
    private var capture: RecordingCapture?
    private var startupTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var durationTimer: Timer?
    private var timeObserver: Any?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private let exporter = RecordingExporter()
    private var pendingClose = false
    private var startupFailure: Error?
    private var startedAt = 0.0
    private var previousApplication: NSRunningApplication?

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "recordingOptions.v1"), let value = try? JSONDecoder().decode(RecordingOptions.self, from: data) { options = value }
        if !(0...2).contains(options.sourceKind) { options.sourceKind = 0 }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.position = max(0, time.seconds.isFinite ? time.seconds : 0) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.isPlaying = false
            }
        }
    }

    func present() {
        if isRecording || phase == .countdown || phase == .preparing { hud?.orderFrontRegardless(); return }
        if phase == .preview || phase == .exporting { previewWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        presentSetup()
    }

    func presentSetup() {
        guard !isBusy else { return }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = app }
        player.pause()
        isPlaying = false
        previewWindow?.orderOut(nil)
        phase = .idle
        error = nil
        if setupWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 570, height: 740), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "轻截 · 录屏"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: RecordingSetupView(model: self))
            window.center()
            setupWindow = window
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await refreshSources() }
    }

    func refreshSources() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        if !cameras.contains(where: { $0.uniqueID == options.cameraID }) { options.cameraID = "" }
        if !microphones.contains(where: { $0.uniqueID == options.microphoneID }) { options.microphoneID = "" }
        do {
            let content = try await CaptureService.content(excludingDesktopWindows: false)
            displays = content.displays
            windows = content.windows.filter { $0.windowLayer == 0 && $0.frame.width >= 80 && $0.frame.height >= 80 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
            if !displays.contains(where: { $0.displayID == displayID }) {
                let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? displays.first?.displayID ?? 0
            }
            if !windows.contains(where: { $0.windowID == windowID }) { windowID = windows.first?.windowID ?? 0 }
            error = nil
            refreshThumbnail()
        } catch {
            let systemError = error as NSError
            if systemError.domain == SCStreamError.errorDomain, systemError.code == SCStreamError.Code.userDeclined.rawValue {
                permissionPane = "Privacy_ScreenCapture"
                self.error = "请在系统设置中允许轻截录屏；已授权仍被拒绝时，请移除旧条目并添加当前应用。"
            } else { self.error = error.localizedDescription }
        }
    }

    func displayName(_ display: SCDisplay) -> String {
        let name = screen(for: display.displayID)?.localizedName ?? "显示器"
        return "\(name) · \(display.width) × \(display.height)"
    }

    func windowName(_ window: SCWindow) -> String {
        "\(window.owningApplication?.applicationName ?? "应用") · \(window.title?.isEmpty == false ? window.title! : "未命名窗口")"
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    func refreshThumbnail() {
        thumbnailTask?.cancel()
        sourceImage = nil
        guard options.sourceKind < 2 else { return }
        thumbnailTask = Task {
            do {
                let content = try await CaptureService.content(excludingDesktopWindows: false)
                let target = try target(in: content)
                guard let config = target.configuration, let filter = target.filter else { return }
                let size = RecordingGeometry.videoSize(aspect: target.size.width / target.size.height, longEdge: 900)
                config.width = Int(size.width)
                config.height = Int(size.height)
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                try Task.checkCancellation()
                sourceImage = NSImage(cgImage: image, size: size)
            } catch { if !Task.isCancelled { sourceImage = nil } }
        }
    }

    private func target(in content: SCShareableContent) throws -> RecordingTarget {
        if options.sourceKind == 1 {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.message("选中的窗口已关闭，请刷新后重新选择。") }
            return RecordingTarget.window(window, frameRate: options.frameRate)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }), let screen = screen(for: displayID) else {
            throw CaptureError.message("选中的显示器已断开，请刷新后重新选择。")
        }
        return RecordingTarget.display(display, screen: screen, content: content, frameRate: options.frameRate, hideDesktopIcons: options.hideDesktopIcons)
    }

    func start() {
        guard !isBusy, canStart?() != false else { return }
        error = nil
        permissionPane = nil
        message = ""
        phase = .preparing
        startupFailure = nil
        thumbnailTask?.cancel()
        startupTask = Task {
            do {
                if !options.microphoneID.isEmpty { try await requestPermission(.audio, name: "麦克风") }
                if !options.cameraID.isEmpty { try await requestPermission(.video, name: "摄像头") }
                if options.recordShortcuts, !AXIsProcessTrusted() {
                    permissionPane = "Privacy_Accessibility"
                    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                    throw CaptureError.message("显示快捷键需要辅助功能权限。请授权后再开始，或关闭「记录快捷键」。")
                }
                try Task.checkCancellation()
                let selected: RecordingTarget
                if options.sourceKind == 2 {
                    setupWindow?.orderOut(nil)
                    phase = .choosing
                    try await Task.sleep(for: .milliseconds(180))
                    let shots = try await CaptureService.screens()
                    let region: CaptureRegion? = await withCheckedContinuation { continuation in
                        let selector = RegionSelector()
                        self.selector = selector
                        selector.show(shots: shots, long: false) { region in continuation.resume(returning: region) }
                    }
                    selector = nil
                    guard let region else { phase = .idle; presentSetup(); return }
                    guard region.rect.width >= 32, region.rect.height >= 32 else { throw CaptureError.message("录屏区域至少需要 32 × 32 点，请重新选择。") }
                    let content = try await CaptureService.content(excludingDesktopWindows: false)
                    selected = RecordingTarget.display(region.display, screen: region.screen, content: content, rect: region.rect, frameRate: options.frameRate, hideDesktopIcons: options.hideDesktopIcons)
                } else { selected = try target(in: await CaptureService.content(excludingDesktopWindows: false)) }
                if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "recordingOptions.v1") }
                setupWindow?.orderOut(nil)
                previewWindow?.orderOut(nil)
                previousApplication?.activate()
                player.pause()
                seconds = 0
                phase = .countdown
                showHUD()
                for remaining in stride(from: options.countdown, through: 1, by: -1) {
                    countdown = remaining
                    try await Task.sleep(for: .seconds(1))
                }
                try Task.checkCancellation()
                phase = .preparing
                let document = try RecordingDocument.create(title: selected.title, size: selected.size, pointSize: selected.bounds.size, frameRate: options.frameRate)
                if let data = UserDefaults.standard.data(forKey: "recordingStyle.v1"), let preset = try? JSONDecoder().decode(RecordingStyle.self, from: data) { document.manifest.style = preset }
                document.manifest.style.frameRate = min(document.manifest.style.frameRate, options.frameRate)
                let capture = try RecordingCapture(document: document, target: selected, options: options)
                capture.failed = { [weak self] error in
                    guard let self else { return }
                    if self.phase == .preparing { self.startupFailure = error }
                    else { self.stop(reason: error.localizedDescription) }
                }
                self.capture = capture
                if options.sourceKind == 2 { showBorder(selected.bounds) }
                try await capture.start()
                if let startupFailure { throw startupFailure }
                try Task.checkCancellation()
                startedAt = RecordingMedia.hostTime
                phase = .recording
                showHUD()
                durationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRecording, let capture = self.capture else { return }
                        self.seconds = await capture.duration()
                        self.stateChanged?()
                        if self.phase == .recording, self.seconds == 0, RecordingMedia.hostTime - self.startedAt > 8 {
                            self.stop(reason: "屏幕一直没有提供画面，请检查权限后重试。")
                        }
                    }
                }
            } catch {
                if let capture { _ = try? await capture.stop(); self.capture = nil }
                closeHUD()
                phase = .idle
                presentSetup()
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            startupTask = nil
        }
    }

    private func requestPermission(_ type: AVMediaType, name: String) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: type)
        if status == .authorized { return }
        if status == .notDetermined, await AVCaptureDevice.requestAccess(for: type) { return }
        permissionPane = type == .audio ? "Privacy_Microphone" : "Privacy_Camera"
        throw CaptureError.message("请在系统设置的隐私与安全性中允许轻截访问\(name)，然后重试。")
    }

    func cancelCountdown() {
        guard phase == .countdown || phase == .choosing || phase == .preparing else { return }
        startupTask?.cancel()
        selector?.cancel()
    }

    func togglePause() {
        guard isRecording, let capture else { return }
        let paused = phase != .paused
        phase = paused ? .paused : .recording
        Task { await capture.setPaused(paused) }
    }

    func stop(reason: String? = nil) {
        guard isRecording, let capture else { return }
        phase = .finishing
        durationTimer?.invalidate()
        durationTimer = nil
        Task {
            do {
                let document = try await capture.stop()
                self.capture = nil
                closeHUD()
                open(document)
                if let reason { message = "录制已中断，已保留成功部分。\(reason)" }
            } catch {
                self.capture = nil
                closeHUD()
                phase = .idle
                presentSetup()
                self.error = "\(error.localizedDescription)\n可在录屏文件夹检查已保留的原片。"
            }
        }
    }

    private func showHUD() {
        if hud == nil {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 330, height: 76), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "轻截 · 录制控制"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = NSHostingView(rootView: RecordingHUDView(model: self))
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let screen { panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 165, y: screen.visibleFrame.minY + 28)) }
            hud = panel
        }
        hud?.orderFrontRegardless()
    }

    private func showBorder(_ rect: CGRect) {
        let frame = CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, width: rect.width, height: rect.height).insetBy(dx: -2, dy: -2)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.systemPurple.cgColor
        window.contentView = view
        window.orderFrontRegardless()
        border = window
    }

    private func closeHUD() {
        hud?.orderOut(nil); hud?.close(); hud = nil
        border?.orderOut(nil); border?.close(); border = nil
    }

    func prepareToQuit() -> Bool {
        if isRecording { stop(); return false }
        if phase == .countdown || phase == .preparing || phase == .choosing { cancelCountdown(); return false }
        if isBusy { present(); return false }
        if phase == .preview { previewWindow?.performClose(nil); return phase == .idle }
        return true
    }

    func openDialog() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "打开轻截录屏"
        panel.message = "选择录屏文件夹，或其中的 recording.json。"
        panel.directoryURL = RecordingDocument.libraryURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { open(try RecordingDocument.open(url)) }
        catch { self.error = error.localizedDescription; presentSetup(); self.error = error.localizedDescription }
    }

    func open(_ document: RecordingDocument) {
        previewTask?.cancel()
        self.document = document
        style = document.manifest.style
        seconds = document.manifest.duration
        position = 0
        lastExport = nil
        message = ""
        error = nil
        phase = .preview
        setupWindow?.orderOut(nil)
        if previewWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "轻截 · 录屏预览"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.minSize = CGSize(width: 920, height: 640)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: RecordingPreviewView(model: self))
            window.center()
            previewWindow = window
        }
        previewWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshPreview()
    }

    func refreshPreview() {
        guard let document, phase == .preview else { return }
        previewTask?.cancel()
        rebuilding = true
        let currentStyle = style
        let currentPosition = position
        let playing = isPlaying
        player.pause()
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let composition = try await RecordingComposition.make(document: document, style: currentStyle)
                try Task.checkCancellation()
                let item = composition.playerItem()
                itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    if item.status == .failed { Task { @MainActor [weak self] in self?.error = item.error?.localizedDescription ?? "预览播放失败，原片已保留。" } }
                }
                player.replaceCurrentItem(with: item)
                await player.seek(to: CMTime(seconds: min(currentPosition, max(0, composition.duration - 0.01)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation()
                if playing { player.play() }
                document.manifest.style = currentStyle
                try document.save()
                rebuilding = false
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; rebuilding = false }
            }
        }
    }

    func togglePlayback() {
        guard !rebuilding else { return }
        if isPlaying { player.pause() }
        else {
            if position >= seconds - 0.05 { player.seek(to: .zero) }
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to value: Double) {
        position = value
        player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func export(gif: Bool) {
        guard phase == .preview, let document, let window = previewWindow else { return }
        let panel = NSSavePanel()
        panel.title = gif ? "导出 GIF" : "导出 MP4"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        panel.allowedContentTypes = [gif ? .gif : .mpeg4Movie]
        panel.canCreateDirectories = true
        let name = document.manifest.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(name).\(gif ? "gif" : "mp4")"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.phase = .exporting
            self.exportProgress = 0
            self.error = nil
            self.player.pause()
            self.isPlaying = false
            Task {
                do {
                    try await self.exporter.export(document: document, style: self.style, to: url, gif: gif) { [weak self] progress in self?.exportProgress = progress }
                    self.lastExport = url
                    self.message = "已导出：\(url.lastPathComponent)"
                } catch {
                    if error is CancellationError { self.message = "已取消导出，原片已保留。" }
                    else { self.error = error.localizedDescription }
                }
                self.phase = .preview
                if self.pendingClose { self.pendingClose = false; self.previewWindow?.performClose(nil) }
            }
        }
    }

    func cancelExport() { exporter.cancel() }

    func chooseBackground() {
        guard let document, phase == .preview else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.title = "选择录屏背景"
        guard panel.runModal() == .OK, let url = panel.url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
        do { try RecordingMedia.writePNG(image, to: document.backgroundURL); style.background = .custom; refreshPreview() }
        catch { self.error = error.localizedDescription }
    }

    func savePreset() {
        do {
            var preset = style
            if preset.background == .custom { preset.background = .aurora }
            UserDefaults.standard.set(try JSONEncoder().encode(preset), forKey: "recordingStyle.v1")
            message = "已保存为以后录屏的默认样式。"
        } catch { self.error = error.localizedDescription }
    }

    func revealOriginal() { if let document { NSWorkspace.shared.open(document.directory) } }
    func revealExport() { if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) } }
    func copyExport() {
        guard let lastExport else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([lastExport as NSURL]) { message = "已复制导出文件，可粘贴到访达或聊天窗口。" }
    }

    func openPermissions() {
        guard let permissionPane else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permissionPane)")!)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === setupWindow, isBusy { cancelCountdown(); return false }
        if sender === previewWindow {
            if phase == .exporting { pendingClose = true; cancelExport(); return false }
            previewTask?.cancel()
            player.pause()
            isPlaying = false
            player.replaceCurrentItem(with: nil)
            if let document {
                document.manifest.style = style
                do { try document.save() }
                catch { self.error = error.localizedDescription; return false }
            }
            rebuilding = false
            phase = .idle
        }
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === setupWindow, phase == .idle { Task { await refreshSources() } }
    }

    static func timeLabel(_ time: Double) -> String {
        let value = max(0, Int(time.isFinite ? time : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
