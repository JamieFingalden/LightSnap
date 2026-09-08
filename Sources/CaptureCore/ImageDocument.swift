import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum CaptureError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public enum ImageCodec {
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.message("无法创建剪贴板图片。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.message("图片编码失败。") }
        return data as Data
    }

    public static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= ImageDocument.pixelLimit / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.message("图片尺寸过大或内存不足，请缩小截图区域。")
        }
        return context
    }

    public static func write(_ image: CGImage, to url: URL, jpeg: Bool = false) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
            (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else {
            throw CaptureError.message("无法创建图片文件，请检查保存位置。")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.message("图片写入失败，请检查磁盘空间。")
        }
    }

    public static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw CaptureError.message("截图分块读取失败，请保留窗口并重试。")
        }
        return image
    }
}

public final class ImageDocument {
    // ponytail: 单张图片限制为六千万像素；更大图片需增加分段导出，避免完整编码时内存失控。
    public static let pixelLimit = 60_000_000
    public struct Tile {
        public let url: URL
        public let top: Int
        public let height: Int
    }

    public let width: Int
    public private(set) var height: Int = 0
    public private(set) var tiles: [Tile] = []
    private let directory: URL
    private let cache = NSCache<NSURL, CGImage>()

    public init(width: Int) throws {
        guard width > 0, width <= Self.pixelLimit else { throw CaptureError.message("截图宽度无效。") }
        self.width = width
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LightSnap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache.totalCostLimit = 40 * 1024 * 1024
    }

    deinit {
        do { try FileManager.default.removeItem(at: directory) }
        catch { NSLog("轻截临时分块清理失败：%@", error.localizedDescription) }
    }

    public func append(_ image: CGImage) throws {
        guard image.width == width, image.height <= Self.pixelLimit / width - height else {
            throw CaptureError.message("已达到六千万像素上限，请完成当前长截图后分段截取。")
        }
        let url = directory.appendingPathComponent("\(tiles.count).png")
        try ImageCodec.write(image, to: url)
        tiles.append(Tile(url: url, top: height, height: image.height))
        height += image.height
    }

    public func image(for tile: Tile) throws -> CGImage {
        if let image = cache.object(forKey: tile.url as NSURL) { return image }
        let image = try ImageCodec.read(tile.url)
        cache.setObject(image, forKey: tile.url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }

    // 绘图坐标统一为左上角原点，分块只在进入可见区域时解码。
    public func draw(in context: CGContext, visible: CGRect, caching: Bool = true) throws {
        for tile in tiles {
            let rect = CGRect(x: 0, y: tile.top, width: width, height: tile.height)
            guard rect.intersects(visible) else { continue }
            try autoreleasepool {
                let image = try caching ? self.image(for: tile) : ImageCodec.read(tile.url)
                context.saveGState()
                context.translateBy(x: 0, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: tile.height))
                context.restoreGState()
            }
        }
    }

    public func render(annotations: [Annotation]) throws -> CGImage {
        cache.removeAllObjects()
        let context = try ImageCodec.context(width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        try draw(in: context, visible: CGRect(x: 0, y: 0, width: width, height: height), caching: false)
        for annotation in annotations { annotation.draw(in: context) }
        guard let image = context.makeImage() else { throw CaptureError.message("无法生成导出图片。") }
        return image
    }
}
