import AppKit
import CaptureCore

@MainActor
final class AnnotationCanvas: NSView, NSTextViewDelegate {
    var document: ImageDocument {
        didSet { readErrorShown = false; needsDisplay = true }
    }
    var annotationOrigin = CGPoint.zero { willSet { finishTextEditing() } didSet { needsDisplay = true } }
    var showsImage = true { didSet { needsDisplay = true } }
    var annotations: [Annotation] = []
    let history = UndoManager()
    var selected: Int?
    var tool = 0 { willSet { finishTextEditing() } didSet { window?.invalidateCursorRects(for: self) } }
    var color = NSColor.systemRed.cgColor
    var strokeWidth: CGFloat = 4
    var fontSize: CGFloat = 36
    var dirty = false
    var isExporting = false { willSet { if newValue { finishTextEditing() } } }
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
    private var textEditor: AnnotationTextView?
    private var editingAnnotation: Annotation?
    var isEditingText: Bool { textEditor != nil }
    var scale: CGFloat = 1 {
        willSet { finishTextEditing() }
        didSet {
            frame.size = CGSize(width: CGFloat(document.width) * scale, height: CGFloat(document.height) * scale)
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { history }

    var exportAnnotations: [Annotation] {
        finishTextEditing()
        return annotations.map { annotation in
            var result = annotation
            result.start.x -= annotationOrigin.x; result.end.x -= annotationOrigin.x
            result.start.y -= annotationOrigin.y; result.end.y -= annotationOrigin.y
            return result
        }
    }

    init(document: ImageDocument) {
        self.document = document
        super.init(frame: CGRect(x: 0, y: 0, width: document.width, height: document.height))
        history.levelsOfUndo = 100
        setAccessibilityRole(.image)
        setAccessibilityLabel("截图标注画布")
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档初始化") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == 0 ? .openHand : tool == 5 ? .iBeam : .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard !isExporting, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        let visible = CGRect(x: dirtyRect.minX / scale, y: dirtyRect.minY / scale, width: dirtyRect.width / scale, height: dirtyRect.height / scale)
        if showsImage {
            do { try document.draw(in: context, visible: visible) }
            catch {
                if !readErrorShown {
                    readErrorShown = true
                    DispatchQueue.main.async { [weak self] in self?.failed?(error) }
                }
            }
        }
        // 标注保留在原始截图坐标中，调整选区不改写标注或撤销历史。
        context.translateBy(x: -annotationOrigin.x, y: -annotationOrigin.y)
        for (index, annotation) in annotations.enumerated() where textEditor == nil || index != selected { annotation.draw(in: context) }
        draft?.draw(in: context)
        if textEditor == nil, let selected, annotations.indices.contains(selected) {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1 / scale)
            context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
            context.stroke(annotations[selected].bounds.insetBy(dx: -5 / scale, dy: -5 / scale))
        }
        context.restoreGState()
    }
    private func point(_ event: NSEvent) -> CGPoint {
        imagePoint(convert(event.locationInWindow, from: nil))
    }
    private func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: annotationOrigin.x + min(CGFloat(document.width), max(0, point.x / scale)),
                y: annotationOrigin.y + min(CGFloat(document.height), max(0, point.y / scale)))
    }
    func annotation(atViewPoint point: CGPoint) -> Int? {
        let point = imagePoint(point)
        return annotations.indices.reversed().first { annotations[$0].contains(point, tolerance: 7 / scale) }
    }
    override func mouseDown(with event: NSEvent) {
        guard !isExporting else { return }
        finishTextEditing()
        window?.makeFirstResponder(self)
        let p = point(event)
        let hit = annotation(atViewPoint: convert(event.locationInWindow, from: nil))
        if let hit, annotations[hit].kind == .text, tool == 5 || (tool == 0 && event.clickCount == 2) {
            beginTextEditing(annotations[hit], selected: hit)
            return
        }
        anchor = p
        beforeDrag = annotations
        if tool == 0 {
            selected = annotation(atViewPoint: convert(event.locationInWindow, from: nil))
        } else {
            selected = nil
            draft = Annotation(kind: Annotation.Kind(rawValue: tool - 1)!, start: p, end: p, color: color, lineWidth: strokeWidth, fontSize: fontSize)
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
        if var text = draft, text.kind == .text {
            let rect = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
            text.start = rect.origin
            let width = rect.width >= 8 / scale ? rect.width : min(320 / scale, annotationOrigin.x + CGFloat(document.width) - rect.minX)
            text.end = CGPoint(x: rect.minX + max(text.fontSize, width), y: rect.minY)
            draft = nil
            self.anchor = nil
            beforeDrag = nil
            beginTextEditing(text, selected: nil)
            return
        }
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
        guard !isExporting else { return }
        if var annotation = editingAnnotation, let textEditor {
            annotation.color = color
            annotation.fontSize = fontSize
            editingAnnotation = annotation
            textEditor.font = .systemFont(ofSize: fontSize * scale)
            textEditor.textColor = NSColor(cgColor: color)
            textEditor.insertionPointColor = textEditor.textColor ?? .systemRed
            resizeTextEditor()
            return
        }
        guard let selected else { return }
        register(annotations)
        annotations[selected].color = color
        annotations[selected].lineWidth = strokeWidth
        annotations[selected].fontSize = fontSize
        dirty = true
        needsDisplay = true
    }

    private func beginTextEditing(_ annotation: Annotation, selected: Int?) {
        self.selected = selected
        color = annotation.color
        fontSize = annotation.fontSize
        editingAnnotation = annotation
        let editor = AnnotationTextView(frame: .zero)
        textEditor = editor
        editor.delegate = self
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.font = .systemFont(ofSize: annotation.fontSize * scale)
        editor.textColor = NSColor(cgColor: annotation.color)
        editor.insertionPointColor = editor.textColor ?? .systemRed
        editor.string = annotation.text
        editor.wantsLayer = true
        editor.layer?.borderColor = NSColor.controlAccentColor.cgColor
        editor.layer?.borderWidth = 1
        editor.setAccessibilityLabel("文字标注，Command 加回车完成输入")
        editor.finish = { [weak self] in self?.finishTextEditing() }
        editor.action = { [weak self] key in
            switch key {
            case "s": self?.saveAction?()
            case "t": self?.pinAction?()
            case "w": self?.closeAction?()
            default: break
            }
        }
        addSubview(editor)
        resizeTextEditor()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        changed?()
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) { resizeTextEditor() }

    private func resizeTextEditor() {
        guard let editor = textEditor, var annotation = editingAnnotation else { return }
        annotation.text = editor.string
        let rect = annotation.bounds
        editor.frame = CGRect(x: (rect.minX - annotationOrigin.x) * scale, y: (rect.minY - annotationOrigin.y) * scale,
                              width: rect.width * scale, height: rect.height * scale)
        editor.textContainer?.containerSize = CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)
        if let container = editor.textContainer, let layout = editor.layoutManager {
            layout.ensureLayout(for: container)
            editor.frame.size.height = max(editor.frame.height, ceil(layout.usedRect(for: container).height + layout.extraLineFragmentRect.height))
        }
    }

    func finishTextEditing() {
        guard let editor = textEditor, var annotation = editingAnnotation else { return }
        editor.unmarkText()
        annotation.text = editor.string
        textEditor = nil
        editingAnnotation = nil
        let empty = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let selected {
            let old = annotations[selected]
            if empty || old.text != annotation.text || old.fontSize != annotation.fontSize || old.color != annotation.color {
                register(annotations)
                if empty { annotations.remove(at: selected); self.selected = nil }
                else { annotations[selected] = annotation }
                dirty = true
            }
        } else if !empty {
            register(annotations)
            annotations.append(annotation)
            selected = annotations.count - 1
            dirty = true
        }
        editor.finish = nil
        window?.makeFirstResponder(self)
        editor.removeFromSuperview()
        changed?()
        needsDisplay = true
    }

    func undoEdit() { finishTextEditing(); history.undo() }
    func redoEdit() { finishTextEditing(); history.redo() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let textEditor { return textEditor.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copyAction?(); return true
            case "s": saveAction?(); return true
            case "t": pinAction?(); return true
            case "w": closeAction?(); return true
            case "z":
                guard !isExporting else { return true }
                if event.modifierFlags.contains(.shift) { redoEdit() } else { undoEdit() }
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

private final class AnnotationTextView: NSTextView {
    var finish: (() -> Void)?
    var action: ((String) -> Void)?
    private let textHistory = UndoManager()
    override var undoManager: UndoManager? { textHistory }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { finish?() }
        return resigned
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            if event.keyCode == 36 || event.keyCode == 76 { finish?(); return true }
            if ["s", "t", "w"].contains(key) { action?(key); return true }
            switch key {
            case "c": copy(nil); return true
            case "x": cut(nil); return true
            case "v": pasteAsPlainText(nil); return true
            case "a": selectAll(nil); return true
            case "z":
                if event.modifierFlags.contains(.shift) { textHistory.redo() } else { textHistory.undo() }
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
