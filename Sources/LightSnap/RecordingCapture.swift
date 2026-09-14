import AppKit
import AVFoundation
import ApplicationServices
import ScreenCaptureKit
import CaptureCore

struct RecordingTarget {
    let title: String
    let filter: SCContentFilter?
    let configuration: SCStreamConfiguration?
    let bounds: CGRect
    let size: CGSize
    var windowID: CGWindowID?

    @MainActor
    static func display(_ display: SCDisplay, screen: NSScreen, content: SCShareableContent, rect: CGRect? = nil, frameRate: Int, hideDesktopIcons: Bool = false) -> RecordingTarget {
        let config = CaptureService.configuration(display: display, screen: screen, rect: rect)
        let size = RecordingGeometry.videoSize(aspect: Double(config.width) / Double(config.height), longEdge: min(3840, max(config.width, config.height)))
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(frameRate))
        let bounds = rect.map { $0.offsetBy(dx: CGDisplayBounds(display.displayID).minX, dy: CGDisplayBounds(display.displayID).minY) }
            ?? CGDisplayBounds(display.displayID)
        let desktopIcons = hideDesktopIcons ? content.windows.filter { $0.windowLayer == CGWindowLevelForKey(.desktopIconWindow) } : []
        return RecordingTarget(title: rect == nil ? screen.localizedName : "区域录屏", filter: CaptureService.filter(display: display, content: content, excludingWindows: desktopIcons),
                               configuration: config, bounds: bounds, size: size)
    }

    @MainActor
    static func window(_ window: SCWindow, frameRate: Int) -> RecordingTarget {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = RecordingGeometry.videoSize(aspect: filter.contentRect.width / filter.contentRect.height,
                                               longEdge: min(3840, Int(max(filter.contentRect.width, filter.contentRect.height) * CGFloat(filter.pointPixelScale))))
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(frameRate))
        if #available(macOS 14.2, *) { config.includeChildWindows = true }
        return RecordingTarget(title: window.title?.isEmpty == false ? window.title! : window.owningApplication?.applicationName ?? "窗口录屏",
                               filter: filter, configuration: config, bounds: window.frame, size: size, windowID: window.windowID)
    }
}

// 视频、音频和鼠标时间只在 queue 上修改；设备启停交给单独的队列，避免阻塞样本回调。
final class RecordingWriter: NSObject, SCStreamOutput, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.jamie.LightSnap.recording", qos: .userInitiated)
    private let deviceQueue = DispatchQueue(label: "local.jamie.LightSnap.devices", qos: .userInitiated)
    let auxiliarySession = AVCaptureSession()
    private let cameraOutput = AVCaptureVideoDataOutput()
    private let microphoneOutput = AVCaptureAudioDataOutput()
    private let document: RecordingDocument
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInputs: [String: AVAssetWriterInput] = [:]
    private var cameraWriter: AVAssetWriter?
    private var cameraInput: AVAssetWriterInput?
    private var cameraAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var clock = RecordingClock()
    private var bounds: CGRect
    private var contentRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let tracksWindow: Bool
    private var lastFrame: CVPixelBuffer?
    private var latestFrame: CVPixelBuffer?
    private var pauseRequested = false
    private var lastCameraFrame: CVPixelBuffer?
    private var lastVideoTime = -1.0
    private var lastCameraTime = -1.0
    private var lastAudioTimes: [String: Double] = [:]
    private var cutoff = Double.infinity
    private var finished = false
    private var failure: Error?
    private var observers: [NSObjectProtocol] = []
    var failed: ((Error) -> Void)?

    init(document: RecordingDocument, target: RecordingTarget, options: RecordingOptions) throws {
        self.document = document
        bounds = target.bounds
        tracksWindow = target.windowID != nil
        writer = try AVAssetWriter(outputURL: document.movieURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: RecordingMedia.videoSettings(size: target.size, frameRate: options.frameRate))
        videoInput.expectsMediaDataInRealTime = true
        videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                                                                    kCVPixelBufferWidthKey as String: Int(target.size.width),
                                                                                                                    kCVPixelBufferHeightKey as String: Int(target.size.height),
                                                                                                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        super.init()
        guard writer.canAdd(videoInput) else { throw CaptureError.message("无法创建录屏视频轨道。") }
        writer.add(videoInput)
        for (kind, enabled, channels) in [("系统声音", options.systemAudio, 2), ("麦克风", !options.microphoneID.isEmpty, 1)] where enabled {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                            AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels * 96000])
            input.expectsMediaDataInRealTime = true
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = kind as NSString
            input.metadata = [title]
            guard writer.canAdd(input) else { throw CaptureError.message("无法创建\(kind)轨道。") }
            writer.add(input)
            audioInputs[kind] = input
        }
    }

    func startDevices(options: RecordingOptions) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            deviceQueue.async {
                do {
                    if !options.cameraID.isEmpty {
                        guard let camera = AVCaptureDevice(uniqueID: options.cameraID) else { throw CaptureError.message("选中的摄像头已断开。") }
                        try self.add(camera, to: self.auxiliarySession)
                        if self.auxiliarySession.canSetSessionPreset(.hd1280x720) { self.auxiliarySession.sessionPreset = .hd1280x720 }
                        self.cameraOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        self.cameraOutput.alwaysDiscardsLateVideoFrames = true
                        self.cameraOutput.setSampleBufferDelegate(self, queue: self.queue)
                        try self.add(self.cameraOutput, to: self.auxiliarySession)
                    }
                    if !options.microphoneID.isEmpty {
                        guard let microphone = AVCaptureDevice(uniqueID: options.microphoneID) else { throw CaptureError.message("选中的麦克风已断开。") }
                        try self.add(microphone, to: self.auxiliarySession)
                        self.microphoneOutput.setSampleBufferDelegate(self, queue: self.queue)
                        try self.add(self.microphoneOutput, to: self.auxiliarySession)
                    }
                    let session = self.auxiliarySession
                    if !session.inputs.isEmpty {
                        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                            let observer = NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
                                let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "录制设备被中断。"
                                self?.queue.async { [weak self] in self?.fail(CaptureError.message(message)) }
                            }
                            self.observers.append(observer)
                        }
                        session.startRunning()
                        guard session.isRunning else { throw CaptureError.message("录制设备未能启动，请检查设备连接和系统权限。") }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func add(_ device: AVCaptureDevice, to session: AVCaptureSession) throws {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.message("无法使用设备：\(device.localizedName)。") }
        session.addInput(input)
    }

    private func add(_ output: AVCaptureOutput, to session: AVCaptureSession) throws {
        guard session.canAddOutput(output) else { throw CaptureError.message("无法创建录制设备输出。") }
        session.addOutput(output)
    }

    func stopDevices() async {
        await withCheckedContinuation { continuation in
            deviceQueue.async {
                for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
                self.observers.removeAll()
                if self.auxiliarySession.isRunning { self.auxiliarySession.stopRunning() }
                continuation.resume()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !finished else { return }
        if type == .screen {
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let status = info[.status] as? Int, SCFrameStatus(rawValue: status) == .complete else { return }
            if tracksWindow {
                if let rect = Self.rect(info[.screenRect]), rect.width > 0, rect.height > 0 { bounds = rect }
                if let rect = Self.rect(info[.contentRect]), let scale = info[.scaleFactor] as? CGFloat {
                    contentRect = CGRect(x: rect.minX * scale / document.manifest.size.width, y: rect.minY * scale / document.manifest.size.height,
                                         width: rect.width * scale / document.manifest.size.width, height: rect.height * scale / document.manifest.size.height)
                }
            }
            receive(sampleBuffer, kind: "屏幕", hostTime: sampleBuffer.presentationTimeStamp.seconds)
        } else if type == .audio {
            receive(sampleBuffer, kind: "系统声音", hostTime: sampleBuffer.presentationTimeStamp.seconds)
        }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        if let value = value as? NSValue { return value.rectValue }
        guard let dictionary = value as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let sourceClock = auxiliarySession.synchronizationClock else { return }
        let time = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: sourceClock, to: CMClockGetHostTimeClock()).seconds
        let kind = output === cameraOutput ? "摄像头" : "麦克风"
        receive(sampleBuffer, kind: kind, hostTime: time)
    }

    // 同一入口也用于合成样本检查，实际录屏和验证共用时间戳与写入逻辑。
    func receive(_ sample: CMSampleBuffer, kind: String, hostTime: Double) {
        guard !finished, failure == nil, sample.isValid, hostTime.isFinite, hostTime <= cutoff else { return }
        if kind == "屏幕", let buffer = sample.imageBuffer { appendScreen(buffer, at: hostTime); return }
        guard !pauseRequested else { return }
        guard let seconds = clock.time(at: hostTime) else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        do {
            if kind == "摄像头", let buffer = sample.imageBuffer {
                if cameraWriter == nil {
                    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                    let cameraWriter = try AVAssetWriter(outputURL: document.cameraURL, fileType: .mov)
                    cameraWriter.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
                    let input = AVAssetWriterInput(mediaType: .video, outputSettings: RecordingMedia.videoSettings(size: size, frameRate: 30))
                    input.expectsMediaDataInRealTime = true
                    guard cameraWriter.canAdd(input) else { throw CaptureError.message("无法创建摄像头视频轨道。") }
                    cameraWriter.add(input)
                    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
                    guard cameraWriter.startWriting() else { throw cameraWriter.error ?? CaptureError.message("无法开始写入摄像头视频。") }
                    cameraWriter.startSession(atSourceTime: .zero)
                    self.cameraWriter = cameraWriter
                    cameraInput = input
                    cameraAdaptor = adaptor
                }
                lastCameraFrame = buffer
                guard seconds > lastCameraTime, cameraInput?.isReadyForMoreMediaData == true else { return }
                guard cameraAdaptor?.append(buffer, withPresentationTime: time) == true else { throw cameraWriter?.error ?? CaptureError.message("摄像头视频写入失败。") }
                lastCameraTime = seconds
            } else if let input = audioInputs[kind] {
                guard seconds > (lastAudioTimes[kind] ?? -1), input.isReadyForMoreMediaData else { return }
                let adjusted = try Self.retime(sample, to: time)
                guard input.append(adjusted) else { throw writer.error ?? CaptureError.message("\(kind)写入失败。") }
                lastAudioTimes[kind] = seconds
            }
        } catch { fail(error) }
    }

    private func appendScreen(_ buffer: CVPixelBuffer, at hostTime: Double) {
        latestFrame = buffer
        guard !pauseRequested else { return }
        if clock.origin == nil {
            guard writer.startWriting() else { fail(writer.error ?? CaptureError.message("无法开始写入录屏。")); return }
            clock.start(at: hostTime)
            writer.startSession(atSourceTime: .zero)
        }
        guard let seconds = clock.time(at: hostTime), seconds > lastVideoTime else { return }
        lastFrame = buffer
        guard videoInput.isReadyForMoreMediaData else { return }
        guard videoAdaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 1_000_000)) else {
            fail(writer.error ?? CaptureError.message("录屏视频写入失败。")); return
        }
        lastVideoTime = seconds
    }

    static func retime(_ sample: CMSampleBuffer, to time: CMTime) throws -> CMSampleBuffer {
        var count = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard status == noErr, count > 0 else { throw CaptureError.message("无法读取录音时间戳。") }
        var timings = Array(repeating: CMSampleTimingInfo(), count: count)
        status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil)
        guard status == noErr else { throw CaptureError.message("无法读取录音时间信息。") }
        let delta = CMTimeSubtract(time, sample.presentationTimeStamp)
        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, delta)
            if timings[index].decodeTimeStamp.isValid { timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, delta) }
        }
        var output: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count,
                                                     sampleTimingArray: &timings, sampleBufferOut: &output)
        guard status == noErr, let output else { throw CaptureError.message("无法对齐录音时间。") }
        return output
    }

    func addCursor(_ cursor: RecordedCursor, image: CGImage) {
        queue.async {
            guard !self.finished else { return }
            do {
                try RecordingMedia.writePNG(image, to: self.document.cursorURL(cursor.id))
                self.document.manifest.cursors.append(cursor)
            } catch { self.fail(error) }
        }
    }

    func addPointer(at hostTime: Double, point: CGPoint, visible: Bool, clicked: Bool, cursor: Int) {
        queue.async {
            guard !self.finished, hostTime <= self.cutoff, let time = self.clock.time(at: hostTime), self.bounds.width > 0, self.bounds.height > 0 else { return }
            let x = (point.x - self.bounds.minX) / self.bounds.width
            let y = (point.y - self.bounds.minY) / self.bounds.height
            let visible = visible && x >= 0 && y >= 0 && x <= 1 && y <= 1
            self.document.manifest.pointers.append(RecordingPointer(time: time, x: self.contentRect.minX + x * self.contentRect.width,
                                                                   y: self.contentRect.minY + y * self.contentRect.height,
                                                                   visible: visible, clicked: clicked && visible, cursor: cursor))
        }
    }

    func addShortcut(_ label: String, at hostTime: Double) {
        queue.async {
            guard !self.finished, let time = self.clock.time(at: hostTime), hostTime <= self.cutoff else { return }
            self.document.manifest.shortcuts.append(RecordingShortcut(time: time, label: label))
        }
    }

    func setPaused(_ paused: Bool, at time: Double) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.pauseRequested = paused
                if paused { self.clock.pause(at: time) } else { self.clock.resume(at: time) }
                if !paused, let frame = self.latestFrame, self.failure == nil, !self.finished { self.appendScreen(frame, at: time) }
                continuation.resume()
            }
        }
    }

    func duration() async -> Double {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.clock.duration(at: RecordingMedia.hostTime)) }
        }
    }

    func end(at time: Double) { queue.async { self.cutoff = time } }

    private func fail(_ error: Error) {
        guard failure == nil, !finished else { return }
        failure = error
        failed?(error)
    }

    func finish(at stopTime: Double) async throws -> RecordingDocument {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finished = true
                guard self.lastVideoTime >= 0, self.writer.status == .writing else {
                    let error = self.failure ?? self.writer.error ?? CaptureError.message("没有收到可保存的画面，请重新录制。")
                    self.writer.cancelWriting()
                    self.cameraWriter?.cancelWriting()
                    continuation.resume(throwing: error)
                    return
                }
                let duration = max(self.lastVideoTime + 1.0 / Double(self.document.manifest.frameRate), self.clock.duration(at: stopTime))
                let end = CMTime(seconds: duration, preferredTimescale: 1_000_000)
                let last = max(0, duration - 1.0 / Double(self.document.manifest.frameRate))
                // 静止屏幕不会持续送帧，补最后一帧才能保留末尾讲解与暂停前的停留时间。
                if let frame = self.lastFrame, last > self.lastVideoTime, self.videoInput.isReadyForMoreMediaData {
                    if !self.videoAdaptor.append(frame, withPresentationTime: CMTime(seconds: last, preferredTimescale: 1_000_000)) {
                        self.failure = self.writer.error ?? CaptureError.message("无法保存录屏的最后一帧。")
                    }
                }
                self.lastFrame = nil
                self.latestFrame = nil
                self.videoInput.markAsFinished()
                for input in self.audioInputs.values { input.markAsFinished() }
                self.writer.endSession(atSourceTime: end)
                if let camera = self.cameraWriter, camera.status == .writing {
                    if let frame = self.lastCameraFrame, last > self.lastCameraTime, self.cameraInput?.isReadyForMoreMediaData == true {
                        _ = self.cameraAdaptor?.append(frame, withPresentationTime: CMTime(seconds: last, preferredTimescale: 1_000_000))
                    }
                    self.cameraInput?.markAsFinished()
                    camera.endSession(atSourceTime: end)
                }
                self.lastCameraFrame = nil
                self.writer.finishWriting {
                    Task {
                        if let camera = self.cameraWriter, camera.status == .writing { await camera.finishWriting() }
                        guard self.writer.status == .completed else {
                            continuation.resume(throwing: self.writer.error ?? CaptureError.message("录屏保存失败，原始文件仍留在录屏文件夹。"))
                            return
                        }
                        self.document.manifest.duration = duration
                        self.document.manifest.hasCamera = self.cameraWriter?.status == .completed
                        self.document.manifest.hasSystemAudio = self.lastAudioTimes["系统声音"] != nil
                        self.document.manifest.hasMicrophone = self.lastAudioTimes["麦克风"] != nil
                        do { try self.document.save(); continuation.resume(returning: self.document) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            }
        }
    }
}

@MainActor
final class RecordingCapture: NSObject, SCStreamDelegate {
    private let writer: RecordingWriter
    private let target: RecordingTarget
    private let options: RecordingOptions
    private var stream: SCStream?
    private var timer: Timer?
    private var monitors: [Any] = []
    private var cursorCache: [Data: Int] = [:]
    private var cursorID = 0
    private var tick = 0
    private var stopping = false
    var failed: ((Error) -> Void)?
    var cameraSession: AVCaptureSession { writer.auxiliarySession }

    init(document: RecordingDocument, target: RecordingTarget, options: RecordingOptions) throws {
        self.target = target
        self.options = options
        writer = try RecordingWriter(document: document, target: target, options: options)
        super.init()
        writer.failed = { [weak self] error in Task { @MainActor [weak self] in self?.failed?(error) } }
    }

    func start() async throws {
        do {
            guard let config = target.configuration, let filter = target.filter else { throw CaptureError.message("请先选择要录制的屏幕、窗口或区域。") }
            try await writer.startDevices(options: options)
            config.queueDepth = 5
            config.capturesAudio = options.systemAudio
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            config.streamName = "轻截录屏"
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if options.systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
            self.stream = stream
            try await stream.startCapture()
            startTracking()
        } catch {
            await writer.stopDevices()
            if let stream { try? await stream.stopCapture() }
            self.stream = nil
            throw error
        }
    }

    private func startTracking() {
        updateCursor()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                if self.tick % 6 == 0 { self.updateCursor() }
                self.trackPointer(clicked: false)
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.trackPointer(clicked: true) }) { monitors.append(monitor) }
        if options.recordShortcuts, AXIsProcessTrusted(), let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard !event.isARepeat, !event.modifierFlags.intersection([.command, .control]).isEmpty,
                  let key = event.charactersIgnoringModifiers, key.count == 1, let scalar = key.unicodeScalars.first,
                  CharacterSet.alphanumerics.union(.punctuationCharacters).contains(scalar) else { return }
            // 只记录带 Command 或 Control 的快捷键，不记录正文和密码输入。
            let flags = event.modifierFlags
            let label = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key.uppercased()
            self?.writer.addShortcut(label, at: RecordingMedia.hostTime)
        }) { monitors.append(monitor) }
    }

    private func updateCursor() {
        let cursor = NSCursor.currentSystem ?? .arrow
        guard let data = cursor.image.tiffRepresentation else { return }
        if let id = cursorCache[data] { cursorID = id; return }
        // ponytail: 每次录屏最多保留 128 种光标；大量自绘动画光标可升级为独立光标视频轨。
        guard cursorCache.count < 128, let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        cursorID = cursorCache.count
        cursorCache[data] = cursorID
        writer.addCursor(RecordedCursor(id: cursorID, size: cursor.image.size, hotSpot: cursor.hotSpot), image: image)
    }

    private func trackPointer(clicked: Bool) {
        guard let point = CGEvent(source: nil)?.location else { return }
        let cocoa = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        let overControls = NSApp.windows.contains { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(cocoa) }
        writer.addPointer(at: RecordingMedia.hostTime, point: point, visible: !overControls, clicked: clicked, cursor: cursorID)
    }

    func setPaused(_ paused: Bool) async { await writer.setPaused(paused, at: RecordingMedia.hostTime) }
    func duration() async -> Double { await writer.duration() }

    func stop() async throws -> RecordingDocument {
        stopping = true
        let time = RecordingMedia.hostTime
        writer.end(at: time)
        timer?.invalidate()
        timer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let stream {
            do { try await stream.stopCapture() }
            catch { NSLog("停止录屏时收到系统提示：%@", error.localizedDescription) }
        }
        stream = nil
        await writer.stopDevices()
        return try await writer.finish(at: time)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopping else { return }
            self.failed?(error)
        }
    }
}
