import AppKit

enum SnapStyle {
    static let accent = NSColor(calibratedRed: 0.25, green: 0.50, blue: 0.66, alpha: 1)
    static let ink = NSColor(calibratedWhite: 0.22, alpha: 1)
}

final class ToolButton: NSButton {
    var chosen = false { didSet { needsDisplay = true } }
    var swatch: NSColor?
    var dot: CGFloat?
    var emphasized = false
    private var hovering = false

    init(symbol: String, label: String, target: AnyObject?, action: Selector?) {
        super.init(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        self.target = target
        self.action = action
        title = ""
        toolTip = label
        setAccessibilityLabel(label)
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档初始化") }
    override var acceptsFirstResponder: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if chosen || hovering || isHighlighted {
            (chosen ? SnapStyle.accent.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.045)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        if let swatch {
            let box = CGRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
            swatch.setFill()
            NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            if chosen {
                SnapStyle.accent.setStroke()
                let outline = NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: 4, yRadius: 4)
                outline.lineWidth = 1.5
                outline.stroke()
            }
        } else if let dot {
            (chosen ? SnapStyle.accent : SnapStyle.ink).setFill()
            NSBezierPath(ovalIn: CGRect(x: (bounds.width - dot) / 2, y: (bounds.height - dot) / 2, width: dot, height: dot)).fill()
        } else if let image {
            let tinted = NSImage(size: image.size)
            tinted.lockFocus()
            (chosen || emphasized ? SnapStyle.accent : SnapStyle.ink).setFill()
            CGRect(origin: .zero, size: image.size).fill()
            image.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
            tinted.unlockFocus()
            let rect = CGRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.3, respectFlipped: true, hints: nil)
        }
    }
}

final class ToolStrip: NSView {
    private var position: CGFloat = 7
    init(height: CGFloat = 42) {
        super.init(frame: CGRect(x: 0, y: 0, width: 14, height: height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        layer?.borderWidth = 0.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        setAccessibilityRole(.toolbar)
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档初始化") }
    func add(_ view: NSView, width: CGFloat = 32) {
        view.frame = CGRect(x: position, y: (frame.height - 30) / 2, width: width, height: 30)
        addSubview(view)
        position += width
        frame.size.width = position + 7
    }
    func separator() {
        let line = NSView(frame: CGRect(x: position + 5, y: 10, width: 1, height: frame.height - 20))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
        addSubview(line)
        position += 11
        frame.size.width = position + 7
    }
}

final class EditorBackdrop: NSView {
    var background: CGImage?
    var selection = CGRect.zero { didSet { needsDisplay = true } }
    var showHandles = true { didSet { needsDisplay = true } }
    var dimensions = "" { didSet { needsDisplay = true } }
    var status = "" { didSet { needsDisplay = true } }
    var resizeFinished: ((CGRect) -> Void)?
    var resizing: ((Bool) -> Void)?
    private var initial = CGRect.zero
    private var handle: Int?
    override var isFlipped: Bool { true }

    private var handles: [CGPoint] {
        [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.midX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
         CGPoint(x: selection.minX, y: selection.midY), CGPoint(x: selection.maxX, y: selection.midY),
         CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.midX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)]
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let background {
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(background, in: bounds)
            context.restoreGState()
        }
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(selection)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(background == nil ? 0.48 : 0.4).setFill()
        shade.fill()
        SnapStyle.accent.setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 1.5
        outline.stroke()
        if showHandles {
            for point in handles {
                let box = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
                NSColor.white.setFill()
                box.fill()
                SnapStyle.accent.setStroke()
                NSBezierPath(rect: box).stroke()
            }
        }
        let text = status.isEmpty ? dimensions : status
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let tag = CGRect(x: selection.minX, y: max(6, selection.minY - 28), width: size.width + 14, height: 21)
        NSColor.black.withAlphaComponent(0.53).setFill()
        NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(at: CGPoint(x: tag.minX + 7, y: tag.minY + 4), withAttributes: attributes)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if showHandles, background != nil, handles.contains(where: { hypot($0.x - point.x, $0.y - point.y) < 8 }) { return self }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        guard showHandles, background != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        handle = handles.firstIndex { hypot($0.x - p.x, $0.y - p.y) < 8 }
        initial = selection
        if handle != nil { resizing?(true) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let handle else { return }
        let p = convert(event.locationInWindow, from: nil)
        var left = initial.minX, right = initial.maxX, top = initial.minY, bottom = initial.maxY
        if [0, 3, 5].contains(handle) { left = max(2, min(p.x, right - 12)) }
        if [2, 4, 7].contains(handle) { right = min(bounds.width - 2, max(p.x, left + 12)) }
        if [0, 1, 2].contains(handle) { top = max(2, min(p.y, bottom - 12)) }
        if [5, 6, 7].contains(handle) { bottom = min(bounds.height - 2, max(p.y, top + 12)) }
        selection = CGRect(x: left, y: top, width: right - left, height: bottom - top).integral
    }
    override func mouseUp(with event: NSEvent) {
        guard handle != nil else { return }
        handle = nil
        resizeFinished?(selection)
    }
}
