import Foundation
import CoreGraphics
import CoreText

public struct Annotation {
    public enum Kind: Int, CaseIterable { case rectangle, ellipse, arrow, line, text }
    public var kind: Kind
    public var start: CGPoint
    public var end: CGPoint
    public var color: CGColor
    public var lineWidth: CGFloat
    public var text: String
    public var fontSize: CGFloat

    public init(kind: Kind, start: CGPoint, end: CGPoint, color: CGColor, lineWidth: CGFloat, text: String = "", fontSize: CGFloat = 36) {
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.fontSize = fontSize
    }

    public var bounds: CGRect {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        guard kind == .text else { return rect }
        let size = CTFramesetterSuggestFrameSizeWithConstraints(textFramesetter, CFRange(), nil,
            CGSize(width: max(1, rect.width), height: .greatestFiniteMagnitude), nil)
        return CGRect(origin: rect.origin, size: CGSize(width: max(1, rect.width), height: max(fontSize * 1.3, ceil(size.height) + 2)))
    }

    private var textFramesetter: CTFramesetter {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.system, fontSize, nil)!,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    public var path: CGPath {
        let path = CGMutablePath()
        switch kind {
        case .rectangle: path.addRect(bounds)
        case .ellipse: path.addEllipse(in: bounds)
        case .text: path.addRect(bounds)
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
        defer { context.restoreGState() }
        if kind == .text {
            let rect = bounds
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(textFramesetter, CFRange(), path, nil), context)
            return
        }
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    public func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if kind == .text { return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        return path.copy(strokingWithWidth: max(lineWidth, tolerance * 2), lineCap: .round,
                  lineJoin: .round, miterLimit: 10).contains(point)
    }
}
