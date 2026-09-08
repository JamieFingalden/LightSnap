import AppKit
import CaptureCore

@MainActor
final class AnnotationCanvas: NSView {
    let document: ImageDocument
    var annotations: [Annotation] = []
    let history = UndoManager()
    var selected: Int?
    var tool = 1
    var color = NSColor.systemRed.cgColor
    var strokeWidth: CGFloat = 4
    var dirty = false
    var isExporting = false
    var changed: (() -> Void)?
    var failed: ((Error) -> Void)?
    var copyAction: (() -> Void)?
    var saveAction: (() -> Void)?
    var pinAction: (() -> Void)?
    var closeAction: (() -> Void)?
    private var draft: Annotation?
    private var anchor: CGPoint?
    private var beforeDrag: [Annotation]?
    private var readErrorShown = false
    var scale: CGFloat = 1 {
        didSet {
            frame.size = CGSize(width: CGFloat(document.width) * scale, height: CGFloat(document.height) * scale)
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { history }

    init(document: ImageDocument) {
        self.document = document
        super.init(frame: CGRect(x: 0, y: 0, width: document.width, height: document.height))
        history.levelsOfUndo = 100
        setAccessibilityRole(.image)
        setAccessibilityLabel("截图标注画布")
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档初始化") }

    override func draw(_ dirtyRect: NSRect) {
        guard !isExporting, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        let visible = CGRect(x: dirtyRect.minX / scale, y: dirtyRect.minY / scale, width: dirtyRect.width / scale, height: dirtyRect.height / scale)
        do { try document.draw(in: context, visible: visible) }
        catch {
            if !readErrorShown {
                readErrorShown = true
                DispatchQueue.main.async { [weak self] in self?.failed?(error) }
            }
        }
        for annotation in annotations { annotation.draw(in: context) }
        draft?.draw(in: context)
        if let selected, annotations.indices.contains(selected) {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1 / scale)
            context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
            context.stroke(annotations[selected].bounds.insetBy(dx: -5 / scale, dy: -5 / scale))
        }
        context.restoreGState()
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(CGFloat(document.width), max(0, p.x / scale)), y: min(CGFloat(document.height), max(0, p.y / scale)))
    }
    override func mouseDown(with event: NSEvent) {
        guard !isExporting else { return }
        window?.makeFirstResponder(self)
        let p = point(event)
        anchor = p
        beforeDrag = annotations
        if tool == 0 {
            selected = annotations.indices.reversed().first { annotations[$0].contains(p, tolerance: 7 / scale) }
        } else {
            selected = nil
            draft = Annotation(kind: Annotation.Kind(rawValue: tool - 1)!, start: p, end: p, color: color, lineWidth: strokeWidth)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isExporting, let anchor else { return }
        let p = point(event)
        if draft != nil { draft?.end = p }
        else if let selected, let beforeDrag {
            var annotation = beforeDrag[selected]
            let dx = p.x - anchor.x
            let dy = p.y - anchor.y
            annotation.start.x += dx; annotation.end.x += dx
            annotation.start.y += dy; annotation.end.y += dy
            annotations[selected] = annotation
        }
        autoscroll(with: event)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !isExporting, let anchor else { return }
        let p = point(event)
        if let draft, hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) >= 2 { annotations.append(draft) }
        if let beforeDrag, hypot(p.x - anchor.x, p.y - anchor.y) >= 1, draft != nil || selected != nil {
            register(beforeDrag)
            dirty = true
        }
        draft = nil
        self.anchor = nil
        beforeDrag = nil
        changed?()
        needsDisplay = true
    }
    private func register(_ old: [Annotation]) {
        history.registerUndo(withTarget: self) { target in
            guard !target.isExporting else { return }
            target.register(target.annotations)
            target.annotations = old
            target.selected = nil
            target.dirty = true
            target.changed?()
            target.needsDisplay = true
        }
    }
    func applyStyle() {
        guard !isExporting, let selected else { return }
        register(annotations)
        annotations[selected].color = color
        annotations[selected].lineWidth = strokeWidth
        dirty = true
        needsDisplay = true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copyAction?(); return true
            case "s": saveAction?(); return true
            case "t": pinAction?(); return true
            case "w": closeAction?(); return true
            case "z":
                guard !isExporting else { return true }
                if event.modifierFlags.contains(.shift) { history.redo() } else { history.undo() }
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard !isExporting else { return }
        if event.keyCode == 51 || event.keyCode == 117, let selected {
            register(annotations)
            annotations.remove(at: selected)
            self.selected = nil
            dirty = true
            changed?()
            needsDisplay = true
        } else if event.keyCode == 53 {
            closeAction?()
        } else { super.keyDown(with: event) }
    }
}
