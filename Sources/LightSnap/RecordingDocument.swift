import AppKit
import AVFoundation
import CaptureCore

struct RecordingStyle: Codable, Equatable, Sendable {
    enum Aspect: String, Codable, CaseIterable { case original = "原始比例", wide = "16:9 横屏", portrait = "9:16 竖屏", square = "1:1 方形" }
    enum Background: String, Codable, CaseIterable { case aurora = "极光", ocean = "海蓝", sunset = "日落", graphite = "石墨", white = "纯白", black = "纯黑", custom = "自选图片" }
    enum CameraPosition: String, Codable, CaseIterable { case bottomRight = "右下", bottomLeft = "左下", topRight = "右上", topLeft = "左上" }
    var aspect = Aspect.original
    var background = Background.aurora
    var padding = 0.065
    var cornerRadius = 18.0
    var shadow = 0.45
    var autoZoom = true
    var zoomAmount = 1.7
    var smoothCursor = true
    var cursorSize = 1.6
    var hideIdleCursor = true
    var showClicks = true
    var showShortcuts = true
    var cameraVisible = true
    var cameraPosition = CameraPosition.bottomRight
    var cameraSize = 0.19
    var roundCamera = true
    var mirrorCamera = true
    var systemVolume = 1.0
    var microphoneVolume = 1.0
    var longEdge = 1920
    var frameRate = 60

    func outputSize(source: CGSize) -> CGSize {
        let ratio: Double
        switch aspect {
        case .original: ratio = source.width / max(1, source.height)
        case .wide: ratio = 16.0 / 9
        case .portrait: ratio = 9.0 / 16
        case .square: ratio = 1
        }
        return RecordingGeometry.videoSize(aspect: ratio, longEdge: longEdge)
    }
}

struct RecordingOptions: Codable {
    var sourceKind = 0
    var systemAudio = true
    var hideDesktopIcons = true
    var microphoneID = ""
    var cameraID = ""
    var recordShortcuts = false
    var countdown = 3
    var frameRate = 60
}

struct RecordedCursor: Codable, Sendable {
    let id: Int
    let size: CGSize
    let hotSpot: CGPoint
}

struct RecordingManifest: Codable, Sendable {
    var version = 1
    var title: String
    var createdAt = Date()
    var size: CGSize
    var pointSize: CGSize
    var duration = 0.0
    var frameRate: Int
    var hasCamera = false
    var hasSystemAudio = false
    var hasMicrophone = false
    var pointers: [RecordingPointer] = []
    var shortcuts: [RecordingShortcut] = []
    var cursors: [RecordedCursor] = []
    var style = RecordingStyle()
}

final class RecordingDocument: @unchecked Sendable {
    let directory: URL
    var manifest: RecordingManifest
    var movieURL: URL { directory.appendingPathComponent("screen.mov") }
    var cameraURL: URL { directory.appendingPathComponent("camera.mov") }
    var backgroundURL: URL { directory.appendingPathComponent("background.png") }
    var manifestURL: URL { directory.appendingPathComponent("recording.json") }

    static var libraryURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent("LightSnap", isDirectory: true)
    }

    init(directory: URL, manifest: RecordingManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    static func create(title: String, size: CGSize, pointSize: CGSize, frameRate: Int, root: URL = libraryURL) throws -> RecordingDocument {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let directory = root.appendingPathComponent("\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = RecordingDocument(directory: directory, manifest: RecordingManifest(title: title, size: size, pointSize: pointSize, frameRate: frameRate))
        document.manifest.style.frameRate = frameRate
        try document.save()
        return document
    }

    static func open(_ url: URL) throws -> RecordingDocument {
        let directory = url.lastPathComponent == "recording.json" ? url.deletingLastPathComponent() : url
        let manifestURL = directory.appendingPathComponent("recording.json")
        let values = try manifestURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) < 256 * 1024 * 1024 else { throw CaptureError.message("录屏记录过大，无法打开。") }
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, manifest.size.width.isFinite, manifest.size.height.isFinite,
              manifest.size.width >= 2, manifest.size.height >= 2, manifest.size.width <= 7680, manifest.size.height <= 7680,
              manifest.duration.isFinite, manifest.duration > 0,
              manifest.pointSize.width > 0, manifest.pointSize.height > 0 else {
            throw CaptureError.message("这份录屏尚未完成，或录屏记录已损坏。原始视频仍保留在录屏文件夹中。")
        }
        let document = RecordingDocument(directory: directory, manifest: manifest)
        guard FileManager.default.fileExists(atPath: document.movieURL.path) else { throw CaptureError.message("找不到这份录屏的原始视频。") }
        return document
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    func cursorURL(_ id: Int) -> URL { directory.appendingPathComponent("cursor-\(id).png") }
}

enum RecordingMedia {
    static func videoSettings(size: CGSize, frameRate: Int) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
         AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(80_000_000, max(4_000_000, Int(size.width * size.height) * frameRate / 5)),
                                           AVVideoExpectedSourceFrameRateKey: frameRate,
                                           AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                                           AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
         AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                     AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                     AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CaptureError.message("无法写入录屏图片。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.message("录屏图片保存失败。") }
    }

    static var hostTime: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
