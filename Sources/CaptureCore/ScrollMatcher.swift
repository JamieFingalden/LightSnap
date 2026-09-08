import Foundation
import CoreGraphics

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
    public static func match(previous: GrayFrame, current: GrayFrame) -> ScrollMatch {
        guard previous.width == current.width, previous.height == current.height,
              previous.width >= 16, previous.height >= 96,
              previous.pixels.count == previous.width * previous.height,
              current.pixels.count == current.width * current.height else { return .uncertain }
        let h = current.height
        let w = current.width

        func score(_ shift: Int, rows: Int = 40) -> (error: Double, contrast: Double) {
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

        if score(0).error < 1.2 { return .unchanged }
        let maxShift = h - max(80, h / 5)
        var coarse: [(shift: Int, error: Double)] = []
        for shift in stride(from: 1, through: maxShift, by: 4) {
            coarse.append((shift, score(shift, rows: 24).error))
        }
        let candidates = coarse.sorted { $0.error < $1.error }.prefix(8)
        var refined: [Int: (error: Double, contrast: Double)] = [:]
        for candidate in candidates {
            for shift in max(1, candidate.shift - 3)...min(maxShift, candidate.shift + 3) {
                refined[shift] = score(shift, rows: 64)
            }
        }
        let ranked = refined.sorted { $0.value.error < $1.value.error }
        guard let best = ranked.first, best.value.error < 7, best.value.contrast > 9 else { return .uncertain }
        if let rival = ranked.first(where: { abs($0.key - best.key) > 4 }),
           rival.value.error < best.value.error + 2 { return .uncertain }
        return .append(best.key)
    }
}
