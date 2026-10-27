import Foundation
import CoreGraphics
import CoreVideo
import Vision

public struct GrayFrame {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int

    public init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    public init(image: CGImage) throws {
        let width = min(160, image.width)
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw CaptureError.message("无法分配拼接匹配缓冲区。") }
        self.width = width
        self.height = height
        pixels = bytes
    }
}

public enum ScrollMatch: Equatable {
    case unchanged
    case append(Int)
    case uncertain
}

public enum ScrollMatcher {
    // ponytail: 只匹配向下滚动的单一静态区域；复杂固定栏和双向滚动需独立的区域掩码与轨迹模型。
    private static let joinErrorLimit: Double = 7
    private static let contrastFloor: Double = 9
    private static let rivalMargin: Double = 2

    public static func match(previous: GrayFrame, current: GrayFrame) -> ScrollMatch {
        guard let size = validated(previous: previous, current: current) else { return .uncertain }
        let h = size.height
        if score(previous: previous, current: current, shift: 0).error < 1.2 { return .unchanged }
        let maxShift = h - max(80, h / 5)
        var coarse: [(shift: Int, error: Double)] = []
        for shift in stride(from: 1, through: maxShift, by: 4) {
            coarse.append((shift, score(previous: previous, current: current, shift: shift, rows: 24).error))
        }
        let candidates = coarse.sorted { $0.error < $1.error }.prefix(8)
        var refined: [Int: (error: Double, contrast: Double)] = [:]
        for candidate in candidates {
            for shift in max(1, candidate.shift - 3)...min(maxShift, candidate.shift + 3) {
                refined[shift] = score(previous: previous, current: current, shift: shift, rows: 64)
            }
        }
        let ranked = refined.sorted { $0.value.error < $1.value.error }
        guard let best = ranked.first, best.value.error < joinErrorLimit, best.value.contrast > contrastFloor else { return .uncertain }
        if let rival = ranked.first(where: { abs($0.key - best.key) > 4 }),
           rival.value.error < best.value.error + rivalMargin { return .uncertain }
        return .append(best.key)
    }

    // 快速采样拿不准时的复核路径：Vision 图像配准给出候选平移，最终仍由像素校验裁决是否拼接。
    public static func refine(previousImage: CGImage, currentImage: CGImage,
                              previous: GrayFrame, current: GrayFrame) -> ScrollMatch {
        guard let size = validated(previous: previous, current: current),
              previousImage.width == currentImage.width,
              previousImage.height == currentImage.height,
              previousImage.height == size.height,
              let observation = align(previousImage: previousImage, currentImage: currentImage) else { return .uncertain }
        let maxShift = size.height - max(80, size.height / 5)
        // 配准平移的符号随参考图方向翻转、单位随请求而异；两种符号与两种单位都列为候选，交给像素校验筛选。
        let translation = Double(observation.alignmentTransform.ty)
        var proposals = Set<Int>()
        for value in [translation, -translation, translation * Double(size.height), -translation * Double(size.height)] {
            let shift = Int(value.rounded())
            if (1...maxShift).contains(shift) { proposals.insert(shift) }
        }
        guard !proposals.isEmpty else { return .uncertain }
        var refined: [Int: (error: Double, contrast: Double)] = [:]
        for proposal in proposals {
            for shift in max(1, proposal - 3)...min(maxShift, proposal + 3) {
                refined[shift] = score(previous: previous, current: current, shift: shift, rows: 64)
            }
        }
        let ranked = refined.sorted { $0.value.error < $1.value.error }
        guard let best = ranked.first,
              best.value.error < joinErrorLimit, best.value.contrast > contrastFloor else { return .uncertain }
        // 重复纹理会让相隔整周期的多个平移同样可信；放宽到全范围复核，仍有对手就维持不确定。
        for shift in stride(from: 1, through: maxShift, by: 4) where abs(shift - best.key) > 4 {
            if score(previous: previous, current: current, shift: shift, rows: 24).error < best.value.error + rivalMargin {
                return .uncertain
            }
        }
        return .append(best.key)
    }

    private static func validated(previous: GrayFrame, current: GrayFrame) -> (width: Int, height: Int)? {
        guard previous.width == current.width, previous.height == current.height,
              previous.width >= 16, previous.height >= 96,
              previous.pixels.count == previous.width * previous.height,
              current.pixels.count == current.width * current.height else { return nil }
        return (previous.width, previous.height)
    }

    private static func score(previous: GrayFrame, current: GrayFrame, shift: Int, rows: Int = 40) -> (error: Double, contrast: Double) {
        let h = current.height
        let w = current.width
        let overlap = h - shift
        let margin = max(8, overlap / 10)
        var error = 0.0
        var sum = 0.0
        var square = 0.0
        var count = 0.0
        for row in 0..<rows {
            let y = margin + row * (overlap - margin * 2 - 1) / max(1, rows - 1)
            for column in 0..<32 {
                let x = w / 10 + column * (w * 8 / 10 - 1) / 31
                let old = Double(previous.pixels[(y + shift) * w + x])
                let new = Double(current.pixels[y * w + x])
                error += abs(old - new)
                sum += new
                square += new * new
                count += 1
            }
        }
        return (error / count, sqrt(max(0, square / count - pow(sum / count, 2))))
    }

    private static func align(previousImage: CGImage, currentImage: CGImage) -> VNImageTranslationAlignmentObservation? {
        guard let previousBuffer = try? registrationBuffer(previousImage),
              let currentBuffer = try? registrationBuffer(currentImage) else { return nil }
        // 请求携带的 targeted 是浮动帧（当前画面），交给 handler 的是参考帧（上一画面）；
        // 平移的符号与单位在调用方由候选集兜底，这里不依赖其约定。
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: currentBuffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: previousBuffer)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }

    // 两帧必须走同一条像素缓冲转换路径，方向一致后配准得到的平移才可比。
    private static func registrationBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let created = buffer else { throw CaptureError.message("无法创建配准缓冲区。") }
        CVPixelBufferLockBaseAddress(created, [])
        defer { CVPixelBufferUnlockBaseAddress(created, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(created), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(created), space: ImageCodec.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw CaptureError.message("无法创建配准画布。")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return created
    }
}
