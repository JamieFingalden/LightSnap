import Foundation
import CoreGraphics

public struct Annotation {
    public enum Kind: Int, CaseIterable { case rectangle, ellipse, arrow, line }
    public var kind: Kind
    public var start: CGPoint
    public var end: CGPoint
    public var color: CGColor
    public var lineWidth: CGFloat

    public init(kind: Kind, start: CGPoint, end: CGPoint, color: CGColor, lineWidth: CGFloat) {
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
    }

    public var bounds: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    public var path: CGPath {
        let path = CGMutablePath()
        switch kind {
        case .rectangle: path.addRect(bounds)
        case .ellipse: path.addEllipse(in: bounds)
        case .line, .arrow:
            path.move(to: start)
            path.addLine(to: end)
            if kind == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = min(max(lineWidth * 4, 14), hypot(end.x - start.x, end.y - start.y) * 0.45)
                for side in [-1.0, 1.0] {
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: end.x - length * cos(angle + side * .pi / 6),
                                            y: end.y - length * sin(angle + side * .pi / 6)))
                }
            }
        }
        return path
    }

    public func draw(in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    public func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        path.copy(strokingWithWidth: max(lineWidth, tolerance * 2), lineCap: .round,
                  lineJoin: .round, miterLimit: 10).contains(point)
    }
}
