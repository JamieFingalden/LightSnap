import AppKit
import ScreenCaptureKit
import VideoToolbox
import CaptureCore

// 工作状态只由捕获串行队列访问，回调在启动流前设置。
private final class ScrollWorker: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.jamie.LightSnap.stitch", qos: .userInitiated)
    var update: ((String) -> Void)?
    private var document: ImageDocument?
    private var previous: GrayFrame?
    private var previousImage: CGImage?
    private var stopped = false
    private var lastMessage = ""
    private var lastShift = 0
    private var uncertainStreak = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        autoreleasepool {
            do {
                var output: CGImage?
                let status = VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &output)
                guard status == noErr, let image = output else { throw CaptureError.message("无法读取屏幕画面。") }
                let gray = try GrayFrame(image: image)
                if let previous, let document, let previousImage {
                    var result = ScrollMatcher.match(previous: previous, current: gray)
                    if case .uncertain = result {
                        // 快速采样拿不准时交给 Vision 图像配准复核，仍不确定才提示回滚。
                        result = ScrollMatcher.refine(previousImage: previousImage, currentImage: image,
                                                      previous: previous, current: gray)
                    }
                    switch result {
                    case .unchanged:
                        uncertainStreak = 0
                        notify("已截取 \(document.height) px · 请继续缓慢向下滚动")
                    case .uncertain:
                        uncertainStreak += 1
                        notify(uncertainAdvice(frameHeight: gray.height))
                    case .append(let shift):
                        try accept(shift: shift, image: image, gray: gray, document: document)
                    }
                } else {
                    let document = try ImageDocument(width: image.width)
                    try document.append(image)
                    self.document = document
                    previous = gray
                    previousImage = image
                    notify("已截取 \(document.height) px · 请缓慢向下滚动")
                }
            } catch {
                stopped = true
                notify("\(error.localizedDescription) 已保留成功部分，可点击完成。")
            }
        }
    }

    private func accept(shift: Int, image: CGImage, gray: GrayFrame, document: ImageDocument) throws {
        guard let strip = image.cropping(to: CGRect(x: 0, y: image.height - shift, width: image.width, height: shift)) else {
            throw CaptureError.message("无法裁剪新增内容。")
        }
        try document.append(strip)
        previous = gray
        previousImage = image
        lastShift = shift
        uncertainStreak = 0
        notify(scrolledTooFast(shift: shift, frameHeight: gray.height)
            ? "已截取 \(document.height) px · 滚动偏快，放慢一点更稳"
            : "已截取 \(document.height) px · 请继续缓慢向下滚动")
    }

    // 单帧位移超过半屏即视为滚动偏快；重叠区随之过窄，是拼接失败的主要来源。
    private func scrolledTooFast(shift: Int, frameHeight: Int) -> Bool {
        shift * 2 > frameHeight
    }

    private func uncertainAdvice(frameHeight: Int) -> String {
        guard uncertainStreak > 1 || scrolledTooFast(shift: lastShift, frameHeight: frameHeight) else {
            return "重叠不明确：请回滚到已截位置，再缓慢向下滚动"
        }
        return "滚动过快、重叠不足：请回滚到已截位置，放慢再继续"
    }

    private func notify(_ message: String) {
        guard message != lastMessage else { return }
        lastMessage = message
        update?(message)
    }

    func finish() async -> ImageDocument? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopped = true
                self.previous = nil
                self.previousImage = nil
                let document = self.document
                self.document = nil
                continuation.resume(returning: document)
            }
        }
    }
}

@MainActor
final class LongCapture: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private let worker = ScrollWorker()
    private var panel: NSPanel?
    private var border: NSWindow?
    private let label = NSTextField(labelWithString: "正在开始…")
    private var finishing = false
    var completed: ((ImageDocument?) -> Void)?

    func start(region: CaptureRegion) async throws {
        let content = try await CaptureService.content()
        let config = CaptureService.configuration(display: region.display, screen: region.screen, rect: region.rect)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 6)
        config.queueDepth = 3
        let stream = SCStream(filter: CaptureService.filter(display: region.display, content: content), configuration: config, delegate: self)
        try stream.addStreamOutput(worker, type: .screen, sampleHandlerQueue: worker.queue)
        self.stream = stream
        worker.update = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.label.stringValue = message
                self?.label.toolTip = message
            }
        }
        showControls(region: region)
        do { try await stream.startCapture() }
        catch { cleanup(); self.stream = nil; throw error }
    }

    private func showControls(region: CaptureRegion) {
        let frame = region.screenRect
        let border = NSWindow(contentRect: frame.insetBy(dx: -2, dy: -2), styleMask: .borderless, backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.ignoresMouseEvents = true
        border.level = .floating
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: border.frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = SnapStyle.accent.cgColor
        view.layer?.borderWidth = 1.5
        border.contentView = view
        border.orderFrontRegardless()
        self.border = border

        let controls = ToolStrip()
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = SnapStyle.ink
        label.lineBreakMode = .byTruncatingTail
        controls.add(label, width: 350)
        label.frame.origin.y = 13
        label.frame.size.height = 16
        controls.separator()
        controls.add(ToolButton(symbol: "xmark", label: "取消长截图", target: self, action: #selector(cancelCapture)))
        let finish = ToolButton(symbol: "checkmark", label: "完成并标注", target: self, action: #selector(finishCapture))
        finish.emphasized = true
        controls.add(finish)
        let panel = NSPanel(contentRect: controls.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "轻截 · 长截图"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .aqua)
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = controls
        let visible = region.screen.visibleFrame
        let x = min(max(visible.minX, frame.maxX - panel.frame.width), visible.maxX - panel.frame.width)
        let y = frame.minY - panel.frame.height - 12 >= visible.minY
            ? frame.minY - panel.frame.height - 12 : min(visible.maxY - panel.frame.height, frame.maxY + 12)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    @objc func finishCapture() { finish(keep: true) }
    @objc private func cancelCapture() { finish(keep: false) }

    private func finish(keep: Bool) {
        guard !finishing else { return }
        finishing = true
        label.stringValue = "正在结束截图…"
        Task {
            if let stream {
                do { try await stream.stopCapture() }
                catch { NSLog("停止长截图时收到系统提示：%@", error.localizedDescription) }
            }
            stream = nil
            let document = await worker.finish()
            cleanup()
            completed?(keep ? document : nil)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.label.stringValue = "屏幕捕获已停止，正在保留成功部分。"
            self.finish(keep: true)
        }
    }

    private func cleanup() {
        panel?.orderOut(nil); panel?.close(); panel = nil
        border?.orderOut(nil); border?.close(); border = nil
    }
}
