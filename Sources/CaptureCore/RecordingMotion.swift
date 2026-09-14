import Foundation
import CoreGraphics

public struct RecordingClock {
    public private(set) var origin: Double?
    public private(set) var pausedAt: Double?
    private var pausedDuration = 0.0
    private var validFrom = 0.0

    public init() {}

    public mutating func start(at time: Double) {
        guard origin == nil, time.isFinite else { return }
        origin = time
        validFrom = time
    }

    public mutating func pause(at time: Double) {
        guard origin != nil, pausedAt == nil, time.isFinite else { return }
        pausedAt = max(time, validFrom)
    }

    public mutating func resume(at time: Double) {
        guard let pausedAt, time.isFinite, time >= pausedAt else { return }
        pausedDuration += time - pausedAt
        validFrom = time
        self.pausedAt = nil
    }

    public func time(at time: Double) -> Double? {
        guard let origin, pausedAt == nil, time.isFinite, time >= validFrom else { return nil }
        return max(0, time - origin - pausedDuration)
    }

    public func duration(at time: Double) -> Double {
        guard let origin, time.isFinite else { return 0 }
        return max(0, (pausedAt ?? time) - origin - pausedDuration)
    }
}

public struct RecordingPointer: Codable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double
    public var visible: Bool
    public var clicked: Bool
    public var cursor: Int

    public init(time: Double, x: Double, y: Double, visible: Bool = true, clicked: Bool = false, cursor: Int = 0) {
        self.time = time
        self.x = x
        self.y = y
        self.visible = visible
        self.clicked = clicked
        self.cursor = cursor
    }

    public var point: CGPoint { CGPoint(x: x, y: y) }
}

public struct RecordingShortcut: Codable, Sendable {
    public let time: Double
    public let label: String
    public init(time: Double, label: String) { self.time = time; self.label = label }
}

public struct RecordingMotion: Sendable {
    private let pointers: [RecordingPointer]
    private let smoothed: [RecordingPointer]
    private let focus: [RecordingPointer]
    private let lastMoves: [Double]
    private let clicks: [RecordingPointer]
    private let zooms: [ClosedRange<Double>]

    public init(pointers: [RecordingPointer]) {
        let samples = pointers.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.time >= 0 }
            .sorted { $0.time < $1.time }
        self.pointers = samples
        smoothed = Self.smooth(samples, response: 0.045)
        focus = Self.smooth(samples, response: 0.22)
        clicks = samples.filter { $0.clicked && $0.visible }
        var intervals: [ClosedRange<Double>] = []
        for click in clicks {
            let start = max(0, click.time - 0.4)
            let end = click.time + 2.2
            if let previous = intervals.last, start <= previous.upperBound {
                intervals[intervals.count - 1] = previous.lowerBound...end
            } else { intervals.append(start...end) }
        }
        zooms = intervals
        var moves: [Double] = []
        var lastMove = 0.0
        var previous: RecordingPointer?
        for sample in samples {
            if let previous {
                if hypot(sample.x - previous.x, sample.y - previous.y) > 0.0006 || sample.clicked || sample.visible != previous.visible {
                    lastMove = sample.time
                }
            } else { lastMove = sample.time }
            moves.append(lastMove)
            previous = sample
        }
        lastMoves = moves
    }

    public func pointer(at time: Double, smooth: Bool) -> RecordingPointer? {
        interpolate(smooth ? smoothed : pointers, at: time)
    }

    public func opacity(at time: Double, hideIdle: Bool) -> Double {
        guard let index = index(at: time, in: pointers), pointers[index].visible else { return 0 }
        guard hideIdle else { return 1 }
        return 1 - Self.ease((time - lastMoves[index] - 2.0) / 0.35)
    }

    public func zoom(at time: Double, duration: Double, amount: Double) -> Double {
        let index = upperBound(zooms.count) { zooms[$0].lowerBound <= time } - 1
        guard index >= 0, time <= zooms[index].upperBound else { return 1 }
        let interval = zooms[index]
        let strength = min(Self.ease((time - interval.lowerBound) / 0.65),
                           Self.ease((min(interval.upperBound, duration) - time) / 0.8))
        return 1 + (max(1, amount) - 1) * strength
    }

    public func focalPoint(at time: Double) -> CGPoint {
        guard let value = interpolate(focus, at: time), value.visible else { return CGPoint(x: 0.5, y: 0.5) }
        return value.point
    }

    public func click(at time: Double) -> RecordingPointer? {
        let index = index(at: time, in: clicks)
        guard let index, time - clicks[index].time < 0.45 else { return nil }
        return clicks[index]
    }

    private func interpolate(_ samples: [RecordingPointer], at time: Double) -> RecordingPointer? {
        guard let index = index(at: time, in: samples) else { return nil }
        var value = samples[index]
        if index + 1 < samples.count {
            let next = samples[index + 1]
            // 隐藏、恢复或暂停后跳过插值，避免鼠标从另一块屏幕横穿画面。
            if value.visible == next.visible, next.time - value.time < 0.2 {
                let fraction = max(0, min(1, (time - value.time) / max(0.000001, next.time - value.time)))
                value.x += (next.x - value.x) * fraction
                value.y += (next.y - value.y) * fraction
            }
        }
        return value
    }

    private func index(at time: Double, in samples: [RecordingPointer]) -> Int? {
        let result = upperBound(samples.count) { samples[$0].time <= time } - 1
        return result >= 0 ? result : nil
    }

    private func upperBound(_ count: Int, matching: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if matching(middle) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func smooth(_ samples: [RecordingPointer], response: Double) -> [RecordingPointer] {
        guard samples.count > 1 else { return samples }
        var result = samples
        for index in 1..<samples.count {
            let dt = samples[index].time - samples[index - 1].time
            guard dt > 0, dt < 0.2, samples[index].visible == samples[index - 1].visible else { continue }
            let alpha = 1 - exp(-dt / response)
            result[index].x = result[index - 1].x + (samples[index].x - result[index - 1].x) * alpha
            result[index].y = result[index - 1].y + (samples[index].y - result[index - 1].y) * alpha
        }
        // 双向滤波消除单向平滑的跟随延迟，让鼠标仍与点击时刻对齐。
        for index in stride(from: samples.count - 2, through: 0, by: -1) {
            let dt = samples[index + 1].time - samples[index].time
            guard dt > 0, dt < 0.2, samples[index].visible == samples[index + 1].visible else { continue }
            let alpha = 1 - exp(-dt / response)
            result[index].x = result[index + 1].x + (result[index].x - result[index + 1].x) * alpha
            result[index].y = result[index + 1].y + (result[index].y - result[index + 1].y) * alpha
        }
        return result
    }

    public static func ease(_ value: Double) -> Double {
        let t = max(0, min(1, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

public enum RecordingGeometry {
    public static func videoSize(aspect: Double, longEdge: Int) -> CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? min(20, max(0.05, aspect)) : 16.0 / 9
        let edge = Double(max(2, min(7680, longEdge)))
        let width = ratio >= 1 ? edge : edge * ratio
        let height = ratio >= 1 ? edge / ratio : edge
        return CGSize(width: max(2, floor(width / 2) * 2), height: max(2, floor(height / 2) * 2))
    }

    public static func viewport(source: CGSize, destination: CGSize, focus: CGPoint, zoom: Double) -> CGRect {
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0 else { return .zero }
        let scale = max(destination.width / source.width, destination.height / source.height) * max(1, zoom)
        let size = CGSize(width: min(source.width, destination.width / scale), height: min(source.height, destination.height / scale))
        let x = min(max(0, focus.x * source.width - size.width / 2), source.width - size.width)
        let y = min(max(0, focus.y * source.height - size.height / 2), source.height - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
