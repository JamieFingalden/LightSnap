import AppKit
import AVFoundation
import CoreText
import CaptureCore

@main
struct RecordingCheck {
    static let context = CIContext(options: [.cacheIntermediates: false])

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        checkMotion()
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let size = CGSize(width: 960, height: 600)
        let bounds = CGRect(x: -960, y: -300, width: size.width, height: size.height)
        let target = RecordingTarget(title: "轻截录屏演示", filter: nil, configuration: nil, bounds: bounds, size: size)
        var options = RecordingOptions()
        options.microphoneID = "检查麦克风"
        options.cameraID = "检查摄像头"
        options.frameRate = 30
        let document = try RecordingDocument.create(title: target.title, size: size, pointSize: size, frameRate: 30, root: root)
        let writer = try RecordingWriter(document: document, target: target, options: options)
        writer.failed = { error in NSLog("录屏检查写入失败：%@", error.localizedDescription) }
        let cursor = NSCursor.arrow
        writer.addCursor(RecordedCursor(id: 0, size: cursor.image.size, hotSpot: cursor.hotSpot), image: cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let source = demoImage()
        try RecordingMedia.writePNG(source, to: root.appendingPathComponent("source.png"))
        let camera = cameraImage()
        for index in 0..<60 {
            let host = 100.0 + Double(index) / 15
            if index == 15 { await writer.setPaused(true, at: host) }
            if index == 30 { await writer.setPaused(false, at: host) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.queue.async {
                    do {
                        // 最后一秒只送音频，验证静止屏幕的末帧补齐。
                        if index < 45 { writer.receive(try videoSample(source, at: host), kind: "屏幕", hostTime: host) }
                        if index >= 3 { writer.receive(try videoSample(camera, at: host), kind: "摄像头", hostTime: host) }
                        writer.receive(try audioSample(at: host, channels: 2, frequency: 440), kind: "系统声音", hostTime: host)
                        writer.receive(try audioSample(at: host, channels: 1, frequency: 880), kind: "麦克风", hostTime: host)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            let x = 0.18 + Double(index) / 60 * 0.55
            writer.addPointer(at: host, point: CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + bounds.height * 0.45),
                              visible: true, clicked: index == 10 || index == 42, cursor: 0)
            if index == 9 { writer.addShortcut("⌘K", at: host) }
            try await Task.sleep(for: .milliseconds(12))
        }
        let finished = try await writer.finish(at: 104)
        precondition(abs(finished.manifest.duration - 3) < 0.04, "暂停的一秒必须从成片时长中移除")
        precondition(finished.manifest.hasCamera && finished.manifest.hasSystemAudio && finished.manifest.hasMicrophone, "摄像头与两路音频必须保留")
        precondition(abs((finished.manifest.pointers.first?.x ?? -1) - 0.18) < 0.000001, "副屏的负坐标必须换算到录屏范围内")
        let reopened = try RecordingDocument.open(finished.directory)
        let raw = AVURLAsset(url: reopened.movieURL)
        let audioTracks = try await raw.loadTracks(withMediaType: .audio)
        precondition(audioTracks.count == 2, "系统声音与麦克风必须有独立音轨")
        var names: Set<String> = []
        for track in audioTracks {
            let range = try await track.load(.timeRange)
            precondition(range.end.seconds > 2.8 && range.end.seconds < 3.1, "音轨必须与暂停后的成片时长对齐")
            for item in try await track.load(.metadata) where item.commonKey == .commonKeyTitle {
                if let name = try await item.load(.stringValue) { names.insert(name) }
            }
        }
        precondition(names == ["系统声音", "麦克风"], "音轨名称必须支持独立音量控制")
        var style = reopened.manifest.style
        style.longEdge = 960
        let composition = try await RecordingComposition.make(document: reopened, style: style)
        let generator = AVAssetImageGenerator(asset: composition.asset)
        generator.videoComposition = composition.video
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (name, time) in [("preview-start.png", 0.05), ("preview-zoom.png", 1.1), ("preview-end.png", 2.9)] {
            let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            precondition(image.width == 960 && image.height == 600, "预览必须使用选定的画布尺寸")
            try RecordingMedia.writePNG(image, to: root.appendingPathComponent(name))
        }
        let output = root.appendingPathComponent("demo-\(UUID().uuidString.prefix(6)).mp4")
        let exporter = RecordingExporter()
        try await exporter.export(document: reopened, style: style, to: output, gif: false) { _ in }
        let exported = AVURLAsset(url: output)
        let exportDuration = try await exported.load(.duration).seconds
        precondition(abs(exportDuration - 3) < 0.08, "导出视频必须保留末尾静止画面和声音")
        let exportedAudio = try await exported.loadTracks(withMediaType: .audio)
        precondition(exportedAudio.count == 1, "MP4 应将两路声音混为兼容播放器的单音轨")
        let gif = root.appendingPathComponent("demo-\(UUID().uuidString.prefix(6)).gif")
        try await exporter.export(document: reopened, style: style, to: gif, gif: true) { _ in }
        let gifSource = CGImageSourceCreateWithURL(gif as CFURL, nil)!
        precondition(CGImageSourceGetCount(gifSource) == 45, "三秒 GIF 必须包含 45 帧")
        try reopened.directory.path.write(to: root.appendingPathComponent("latest.txt"), atomically: true, encoding: .utf8)
        print("录屏检查通过：暂停时钟、副屏坐标、缩放边界、末帧补齐、双音轨同步、摄像头、预览、MP4 与 GIF 导出。")
        print("演示录屏：\(reopened.directory.path)")
        print("导出视频：\(output.path)")
    }

    static func checkMotion() {
        var clock = RecordingClock()
        clock.start(at: 100)
        clock.pause(at: 101)
        precondition(clock.time(at: 102) == nil && clock.duration(at: 200) == 1, "暂停时不能写入样本或增长时长")
        clock.resume(at: 103)
        precondition(abs(clock.time(at: 103.25)! - 1.25) < 0.00001 && clock.time(at: 102.99) == nil, "恢复后应舍弃暂停期间延迟到达的样本")
        clock.pause(at: 104)
        clock.resume(at: 109)
        precondition(abs(clock.time(at: 110)! - 3) < 0.00001, "多次暂停不得累积音画偏移")
        let size = RecordingGeometry.videoSize(aspect: 9.0 / 16, longEdge: 3840)
        precondition(size == CGSize(width: 2160, height: 3840), "竖屏 4K 必须保持偶数尺寸")
        for point in [CGPoint(x: -0.5, y: 2), CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 0.5)] {
            let viewport = RecordingGeometry.viewport(source: CGSize(width: 1920, height: 1080), destination: CGSize(width: 600, height: 1000), focus: point, zoom: 2)
            precondition(CGRect(x: 0, y: 0, width: 1920, height: 1080).contains(viewport), "跟随鼠标时不得露出画面边缘")
        }
        let samples = (0..<240).map { index in RecordingPointer(time: Double(index) / 60, x: 0.25, y: 0.5, clicked: index == 60) }
        let motion = RecordingMotion(pointers: samples)
        precondition(motion.zoom(at: 1.2, duration: 4, amount: 1.7) > 1.5, "点击后应该自动放大")
        precondition(motion.zoom(at: 3.99, duration: 4, amount: 1.7) == 1, "成片结尾应该恢复全景")
        precondition(motion.opacity(at: 3.9, hideIdle: true) == 0, "闲置光标应淡出")
    }

    static func demoImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.965, green: 0.97, blue: 0.985, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 960, height: 600))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 548, width: 960, height: 52))
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            ctx.setFillColor(color.cgColor); ctx.fillEllipse(in: CGRect(x: 20 + index * 22, y: 568, width: 12, height: 12))
        }
        draw("LightSnap", at: CGPoint(x: 418, y: 567), size: 15, color: CGColor(gray: 0.45, alpha: 1), in: ctx)
        draw("把操作，变成一段演示。", at: CGPoint(x: 64, y: 449), size: 35, color: CGColor(gray: 0.14, alpha: 1), in: ctx)
        draw("录屏 · 自动缩放 · 一键导出", at: CGPoint(x: 66, y: 410), size: 16, color: CGColor(gray: 0.48, alpha: 1), in: ctx)
        for (index, title) in ["选择画面", "自然呈现", "分享演示"].enumerated() {
            let rect = CGRect(x: 64 + index * 284, y: 125, width: 264, height: 235)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)); ctx.fillPath()
            ctx.setFillColor(CGColor(red: 0.92, green: 0.9, blue: 0.99, alpha: 1)); ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 20, dy: 60), cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
            draw("0\(index + 1)", at: CGPoint(x: rect.minX + 27, y: rect.minY + 112), size: 38, color: CGColor(red: 0.5, green: 0.43, blue: 0.85, alpha: 1), in: ctx)
            draw(title, at: CGPoint(x: rect.minX + 23, y: rect.minY + 27), size: 19, color: CGColor(gray: 0.2, alpha: 1), in: ctx)
        }
        draw("这是一段合成演示，不包含真实屏幕或录音。", at: CGPoint(x: 65, y: 62), size: 14, color: CGColor(gray: 0.52, alpha: 1), in: ctx)
        return ctx.makeImage()!
    }

    static func cameraImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.76, green: 0.84, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        ctx.setFillColor(CGColor(red: 0.34, green: 0.3, blue: 0.58, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 72, y: -65, width: 180, height: 190))
        ctx.setFillColor(CGColor(red: 0.98, green: 0.79, blue: 0.64, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 116, y: 101, width: 88, height: 100))
        ctx.setFillColor(CGColor(red: 0.22, green: 0.21, blue: 0.3, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 112, y: 165, width: 96, height: 50))
        return ctx.makeImage()!
    }

    static func draw(_ text: String, at point: CGPoint, size: CGFloat, color: CGColor, in context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.system, size, "zh-CN" as CFString)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    static func videoSample(_ image: CGImage, at seconds: Double) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        precondition(status == kCVReturnSuccess)
        context.render(CIImage(cgImage: image), to: buffer!)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer!, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let result = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        precondition(result == noErr)
        return sample!
    }

    static func audioSample(at seconds: Double, channels: Int, frequency: Double) throws -> CMSampleBuffer {
        let count = 3200
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                      mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2),
                                                      mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var samples = [Int16](repeating: 0, count: count * channels)
        for index in samples.indices { samples[index] = Int16(sin((seconds + Double(index / channels) / 48000) * frequency * 2 * .pi) * 2400) }
        var block: CMBlockBuffer?
        let length = samples.count * 2
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        samples.withUnsafeBytes { bytes in _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                              sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        precondition(status == noErr)
        return sample!
    }
}
