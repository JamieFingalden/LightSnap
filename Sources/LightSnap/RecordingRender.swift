import AppKit
import AVFoundation
import CoreImage
import CoreText
import UniformTypeIdentifiers
import CaptureCore

struct RecordingComposition {
    let asset: AVMutableComposition
    let video: AVMutableVideoComposition
    let audio: AVMutableAudioMix
    let duration: Double

    static func make(document: RecordingDocument, style: RecordingStyle) async throws -> RecordingComposition {
        let source = AVURLAsset(url: document.movieURL)
        guard let screen = try await source.loadTracks(withMediaType: .video).first else { throw CaptureError.message("原片中没有可播放的视频。") }
        let sourceDuration = try await source.load(.duration)
        let duration = min(sourceDuration.seconds, document.manifest.duration)
        guard duration.isFinite, duration > 0 else { throw CaptureError.message("录屏时长无效。") }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 1_000_000))
        let asset = AVMutableComposition()
        guard let videoTrack = asset.addMutableTrack(withMediaType: .video, preferredTrackID: 1) else { throw CaptureError.message("无法创建录屏预览。") }
        try videoTrack.insertTimeRange(range, of: screen, at: .zero)
        var cameraID: CMPersistentTrackID?
        if document.manifest.hasCamera, style.cameraVisible {
            let cameraAsset = AVURLAsset(url: document.cameraURL)
            if let cameraSource = try await cameraAsset.loadTracks(withMediaType: .video).first,
               let cameraTrack = asset.addMutableTrack(withMediaType: .video, preferredTrackID: 2) {
                let cameraRange = CMTimeRangeGetIntersection(try await cameraSource.load(.timeRange), otherRange: range)
                if cameraRange.duration > .zero {
                    try cameraTrack.insertTimeRange(cameraRange, of: cameraSource, at: cameraRange.start)
                    cameraID = cameraTrack.trackID
                }
            }
        }
        var audioParameters: [AVAudioMixInputParameters] = []
        for track in try await source.loadTracks(withMediaType: .audio) {
            let audioRange = CMTimeRangeGetIntersection(try await track.load(.timeRange), otherRange: range)
            guard audioRange.duration > .zero, let output = asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try output.insertTimeRange(audioRange, of: track, at: audioRange.start)
            let metadata = try await track.load(.metadata)
            var isMicrophone = false
            for item in metadata where item.commonKey == .commonKeyTitle {
                if try await item.load(.stringValue) == "麦克风" { isMicrophone = true }
            }
            let parameters = AVMutableAudioMixInputParameters(track: output)
            parameters.setVolume(Float(min(1, max(0, isMicrophone ? style.microphoneVolume : style.systemVolume))), at: .zero)
            audioParameters.append(parameters)
        }
        let audio = AVMutableAudioMix()
        audio.inputParameters = audioParameters
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = RecordingCompositor.self
        video.renderSize = style.outputSize(source: document.manifest.size)
        video.frameDuration = CMTime(value: 1, timescale: Int32(max(1, min(60, style.frameRate))))
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        video.instructions = [RecordingInstruction(range: range, cameraID: cameraID, renderer: RecordingRenderer(document: document, style: style, size: video.renderSize))]
        return RecordingComposition(asset: asset, video: video, audio: audio, duration: duration)
    }

    func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = video
        item.audioMix = audio
        return item
    }
}

private final class RecordingInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    let cameraID: CMPersistentTrackID?
    let renderer: RecordingRenderer

    init(range: CMTimeRange, cameraID: CMPersistentTrackID?, renderer: RecordingRenderer) {
        timeRange = range
        self.cameraID = cameraID
        self.renderer = renderer
        requiredSourceTrackIDs = ([CMPersistentTrackID(1)] + (cameraID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

final class RecordingCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                      kCVPixelBufferMetalCompatibilityKey as String: true] }
    private let queue = DispatchQueue(label: "local.jamie.LightSnap.render", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? RecordingInstruction,
                      let screen = request.sourceFrame(byTrackID: 1), let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: CaptureError.message("无法读取录屏画面。"))
                    return
                }
                let camera = instruction.cameraID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
                let frame = instruction.renderer.frame(screen: CIImage(cvPixelBuffer: screen), camera: camera, time: request.compositionTime.seconds)
                self.context.render(frame, to: output, bounds: CGRect(origin: .zero, size: request.renderContext.size), colorSpace: self.colorSpace)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() { queue.sync {} }
}

// 预览与导出共用同一渲染器，所有位置使用像素或归一化坐标，切换输出比例后重新计算。
final class RecordingRenderer: @unchecked Sendable {
    private let manifest: RecordingManifest
    private let style: RecordingStyle
    private let motion: RecordingMotion
    private let canvas: CGRect
    private let screenRect: CGRect
    private let background: CIImage
    private let screenMask: CIImage
    private let screenShadow: CIImage
    private let cursors: [Int: (RecordedCursor, CIImage)]
    private let ring: CIImage
    private let badges: [String: CIImage]
    private let unit: CGFloat

    init(document: RecordingDocument, style: RecordingStyle, size: CGSize) {
        manifest = document.manifest
        self.style = style
        motion = RecordingMotion(pointers: manifest.pointers)
        canvas = CGRect(origin: .zero, size: size)
        unit = min(size.width, size.height) / 1080
        let available = canvas.insetBy(dx: min(size.width, size.height) * min(0.22, max(0, style.padding)),
                                      dy: min(size.width, size.height) * min(0.22, max(0, style.padding)))
        if style.aspect == .original {
            let scale = min(available.width / manifest.size.width, available.height / manifest.size.height)
            screenRect = CGRect(x: canvas.midX - manifest.size.width * scale / 2, y: canvas.midY - manifest.size.height * scale / 2,
                                width: manifest.size.width * scale, height: manifest.size.height * scale)
        } else { screenRect = available }
        background = Self.background(style.background, imageURL: document.backgroundURL, in: canvas)
        screenMask = Self.mask(screenRect, radius: max(0, min(80, style.cornerRadius)) * unit)
        screenShadow = Self.shadow(screenMask, radius: 26 * unit, opacity: min(1, max(0, style.shadow)), offset: 10 * unit)
        var images: [Int: (RecordedCursor, CIImage)] = [:]
        for cursor in manifest.cursors.prefix(128) where cursor.id >= 0 {
            if let image = CIImage(contentsOf: document.cursorURL(cursor.id)) { images[cursor.id] = (cursor, image) }
        }
        cursors = images
        ring = Self.makeRing()
        var badges: [String: CIImage] = [:]
        for shortcut in manifest.shortcuts where badges[shortcut.label] == nil { badges[shortcut.label] = Self.badge(shortcut.label) }
        self.badges = badges
    }

    func frame(screen: CIImage, camera: CIImage?, time: Double) -> CIImage {
        let source = screen.transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
        let sourceSize = source.extent.size
        var content = source
        let cursorScale = sourceSize.width / max(1, manifest.pointSize.width) * max(0, min(4, style.cursorSize))
        if style.showClicks, let click = motion.click(at: time) {
            let age = max(0, (time - click.time) / 0.45)
            let side = 42 * cursorScale * (0.6 + age)
            let rect = CGRect(x: click.x * sourceSize.width - side / 2, y: (1 - click.y) * sourceSize.height - side / 2, width: side, height: side)
            content = Self.opacity(Self.fit(ring, in: rect, fill: true), 1 - age).composited(over: content)
        }
        if let pointer = motion.pointer(at: time, smooth: style.smoothCursor), let (cursor, image) = cursors[pointer.cursor] {
            let alpha = motion.opacity(at: time, hideIdle: style.hideIdleCursor)
            let rect = CGRect(x: pointer.x * sourceSize.width - cursor.hotSpot.x * cursorScale,
                              y: (1 - pointer.y) * sourceSize.height - (cursor.size.height - cursor.hotSpot.y) * cursorScale,
                              width: cursor.size.width * cursorScale, height: cursor.size.height * cursorScale)
            if alpha > 0, rect.width > 0 { content = Self.opacity(Self.fit(image, in: rect, fill: false), alpha).composited(over: content) }
        }
        let zoom = style.autoZoom ? motion.zoom(at: time, duration: manifest.duration, amount: min(3, max(1, style.zoomAmount))) : 1
        let focus = style.autoZoom ? motion.focalPoint(at: time) : CGPoint(x: 0.5, y: 0.5)
        let cropped = style.aspect != .original
        let weight = cropped ? 1 : (zoom - 1) / max(0.001, style.zoomAmount - 1)
        let center = CGPoint(x: 0.5 + (focus.x - 0.5) * weight, y: 0.5 + (focus.y - 0.5) * weight)
        let viewport = RecordingGeometry.viewport(source: sourceSize, destination: screenRect.size, focus: center, zoom: zoom)
        let ciViewport = CGRect(x: viewport.minX, y: sourceSize.height - viewport.maxY, width: viewport.width, height: viewport.height)
        let displayed = Self.fit(content.cropped(to: ciViewport), in: screenRect, fill: true)
        var result = Self.clip(displayed, mask: screenMask).composited(over: screenShadow.composited(over: background))
        if let camera, style.cameraVisible {
            let margin = max(24 * unit, min(canvas.width, canvas.height) * min(0.22, max(0, style.padding)) * 0.55)
            let side = min(canvas.width, canvas.height) * min(0.35, max(0.1, style.cameraSize))
            let right = style.cameraPosition == .bottomRight || style.cameraPosition == .topRight
            let top = style.cameraPosition == .topRight || style.cameraPosition == .topLeft
            var rect = CGRect(x: right ? canvas.maxX - margin - side : margin, y: top ? canvas.maxY - margin - side : margin, width: side, height: side)
            if let pointer = motion.pointer(at: time, smooth: true), pointer.visible {
                let position = CGPoint(x: screenRect.minX + (pointer.x * sourceSize.width - viewport.minX) / viewport.width * screenRect.width,
                                       y: screenRect.maxY - (pointer.y * sourceSize.height - viewport.minY) / viewport.height * screenRect.height)
                let distance = hypot(position.x - rect.midX, position.y - rect.midY)
                let factor = 0.72 + 0.28 * RecordingMotion.ease((distance / side - 0.55) / 0.5)
                rect.size = CGSize(width: side * factor, height: side * factor)
                if right { rect.origin.x += side - rect.width }
                if top { rect.origin.y += side - rect.height }
            }
            let mask = Self.mask(rect, radius: style.roundCamera ? rect.width / 2 : 20 * unit)
            var cameraImage = camera
            if style.mirrorCamera { cameraImage = camera.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
            let selfie = Self.clip(Self.fit(cameraImage, in: rect, fill: true), mask: mask)
            result = selfie.composited(over: Self.shadow(mask, radius: 12 * unit, opacity: 0.35, offset: 4 * unit).composited(over: result))
        }
        if style.showShortcuts, let shortcut = manifest.shortcuts.last(where: { $0.time <= time && time - $0.time < 1.6 }), let badge = badges[shortcut.label] {
            let age = time - shortcut.time
            let alpha = min(RecordingMotion.ease(age / 0.12), RecordingMotion.ease((1.6 - age) / 0.25))
            let scale = min(unit, canvas.width * 0.7 / badge.extent.width)
            let rect = CGRect(x: canvas.midX - badge.extent.width * scale / 2, y: 32 * unit,
                              width: badge.extent.width * scale, height: badge.extent.height * scale)
            result = Self.opacity(Self.fit(badge, in: rect, fill: true), alpha).composited(over: result)
        }
        return result.cropped(to: canvas)
    }

    private static func fit(_ image: CIImage, in rect: CGRect, fill: Bool) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        let scale = fill ? max(rect.width / image.extent.width, rect.height / image.extent.height) : min(rect.width / image.extent.width, rect.height / image.extent.height)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.midX - image.extent.width * scale / 2, y: rect.midY - image.extent.height * scale / 2))
            .cropped(to: rect)
    }

    private static func mask(_ rect: CGRect, radius: CGFloat) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": min(radius, min(rect.width, rect.height) / 2), "inputColor": CIColor.white])!.outputImage!
    }

    private static func clip(_ image: CIImage, mask: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
    }

    private static func opacity(_ image: CIImage, _ value: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(1, max(0, value)))])
    }

    private static func shadow(_ mask: CIImage, radius: CGFloat, opacity: Double, offset: CGFloat) -> CIImage {
        mask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                         "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .transformed(by: CGAffineTransform(translationX: 0, y: -offset))
    }

    private static func background(_ style: RecordingStyle.Background, imageURL: URL, in rect: CGRect) -> CIImage {
        if style == .custom, let image = CIImage(contentsOf: imageURL) { return fit(image, in: rect, fill: true) }
        let colors: (CIColor, CIColor)
        switch style {
        case .aurora, .custom: colors = (CIColor(red: 0.20, green: 0.15, blue: 0.45), CIColor(red: 0.59, green: 0.57, blue: 0.92))
        case .ocean: colors = (CIColor(red: 0.04, green: 0.25, blue: 0.40), CIColor(red: 0.25, green: 0.76, blue: 0.78))
        case .sunset: colors = (CIColor(red: 0.87, green: 0.35, blue: 0.40), CIColor(red: 0.97, green: 0.76, blue: 0.54))
        case .graphite: colors = (CIColor(red: 0.11, green: 0.13, blue: 0.18), CIColor(red: 0.29, green: 0.31, blue: 0.38))
        case .white: colors = (.white, .white)
        case .black: colors = (.black, .black)
        }
        return CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: rect.minX, y: rect.maxY), "inputPoint1": CIVector(x: rect.maxX, y: rect.minY),
                                                               "inputColor0": colors.0, "inputColor1": colors.1])!.outputImage!.cropped(to: rect)
    }

    private static func makeRing() -> CIImage {
        let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setStrokeColor(CGColor(red: 0.48, green: 0.55, blue: 1, alpha: 0.9))
        context.setLineWidth(5)
        context.strokeEllipse(in: CGRect(x: 5, y: 5, width: 118, height: 118))
        return CIImage(cgImage: context.makeImage()!)
    }

    private static func badge(_ text: String) -> CIImage {
        let font = CTFontCreateUIFontForLanguage(.system, 34, nil)!
        let string = NSAttributedString(string: String(text.prefix(12)), attributes: [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 1)])
        let line = CTLineCreateWithAttributedString(string)
        let width = Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil))) + 44
        let context = CGContext(data: nil, width: width, height: 68, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.08, alpha: 0.85))
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: 68), cornerWidth: 16, cornerHeight: 16, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: 22, y: 22)
        CTLineDraw(line, context)
        return CIImage(cgImage: context.makeImage()!)
    }
}

@MainActor
final class RecordingExporter {
    private var session: AVAssetExportSession?
    private var gifTask: Task<Void, Error>?
    private var progressTimer: Timer?
    private var cancelled = false

    func cancel() { cancelled = true; session?.cancelExport(); gifTask?.cancel() }

    func export(document: RecordingDocument, style: RecordingStyle, to url: URL, gif: Bool, progress: @escaping @MainActor (Double) -> Void) async throws {
        cancelled = false
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".lightsnap-\(UUID().uuidString).\(gif ? "gif" : "mp4")")
        defer {
            session = nil
            gifTask = nil
            progressTimer?.invalidate()
            progressTimer = nil
            if FileManager.default.fileExists(atPath: temporary.path) { try? FileManager.default.removeItem(at: temporary) }
        }
        var outputStyle = style
        if gif {
            guard document.manifest.duration <= 30 else { throw CaptureError.message("GIF 适合 30 秒以内的片段；这份录屏请导出为 MP4。") }
            outputStyle.longEdge = 960
            outputStyle.frameRate = 15
        }
        let composition = try await RecordingComposition.make(document: document, style: outputStyle)
        guard !cancelled else { throw CancellationError() }
        if gif {
            let task = Task.detached(priority: .userInitiated) {
                let generator = AVAssetImageGenerator(asset: composition.asset)
                generator.videoComposition = composition.video
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let count = max(1, Int(ceil(composition.duration * 15)))
                guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                    throw CaptureError.message("无法创建 GIF 文件。")
                }
                CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                for index in 0..<count {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        let image = try generator.copyCGImage(at: CMTime(value: Int64(index), timescale: 15), actualTime: nil)
                        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 15]] as CFDictionary)
                    }
                    if index % 5 == 0 { await progress(Double(index + 1) / Double(count)) }
                }
                guard CGImageDestinationFinalize(destination) else { throw CaptureError.message("GIF 保存失败。") }
            }
            gifTask = task
            try await task.value
        } else {
            guard let session = AVAssetExportSession(asset: composition.asset, presetName: AVAssetExportPresetHighestQuality) else { throw CaptureError.message("无法创建视频导出任务。") }
            self.session = session
            session.outputURL = temporary
            session.outputFileType = .mp4
            session.videoComposition = composition.video
            session.audioMix = composition.audio
            session.shouldOptimizeForNetworkUse = true
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { progress(Double(self?.session?.progress ?? 0)) }
            }
            await session.export()
            guard session.status == .completed else {
                if session.status == .cancelled { throw CancellationError() }
                throw session.error ?? CaptureError.message("视频导出失败，原片已保留，可以重试。")
            }
        }
        guard !cancelled else { throw CancellationError() }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: url) }
        progress(1)
    }
}
