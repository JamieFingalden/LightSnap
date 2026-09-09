import AppKit
import ApplicationServices

struct SelectionWindow: Equatable {
    let id: CGWindowID
    let processID: pid_t
    let frame: CGRect

    static func snapshot() -> [SelectionWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        // 系统列表按从前到后的顺序排列，必须在截图遮罩出现之前保存。
        return windows.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? NSNumber, pid.int32Value != ownPID,
                  let id = info[kCGWindowNumber as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber, layer.intValue >= 0,
                  let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  isSelectable(frame: frame, layer: layer.intValue, displays: displays) else { return nil }
            return SelectionWindow(id: id.uint32Value, processID: pid.int32Value, frame: frame)
        }
    }

    static func isSelectable(frame: CGRect, layer: Int, displays: [CGRect]) -> Bool {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width >= 3, frame.height >= 3, layer >= 0 else { return false }
        // Dock 和通知中心的透明宿主窗口也会上报 alpha = 1，不能只按矩形和透明度命中。
        // ponytail: 跳过 Dock 层及以上覆盖整屏的宿主窗口；局部面板和普通全屏应用仍保留，整屏高层应用需手动框选。
        return layer < Int(CGWindowLevelForKey(.dockWindow)) || !displays.contains { frame.contains($0) }
    }
}

@MainActor
final class ElementLocator {
    private let queue = DispatchQueue(label: "local.jamie.LightSnap.elementLocator", qos: .userInitiated)
    private var pending: (point: CGPoint, window: SelectionWindow, minimumSize: CGFloat, completion: (CGRect?) -> Void)?
    private var running = false
    private var requestID = 0
    private var preparedApplications = Set<pid_t>()

    func locate(at point: CGPoint, in window: SelectionWindow, minimumSize: CGFloat, completion: @escaping (CGRect?) -> Void) {
        guard window.processID > 0, AXIsProcessTrusted() else { cancel(); completion(nil); return }
        pending = (point, window, minimumSize, completion)
        schedule()
    }

    private func schedule() {
        guard !running, pending != nil else { return }
        running = true
        // 合并移动事件，但不重置定时器，持续移动鼠标时也能获得定位结果。
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
            guard let self else { return }
            guard let request = self.pending else { self.running = false; return }
            self.pending = nil
            let id = self.requestID
            let prepare = self.preparedApplications.insert(request.window.processID).inserted
            self.queue.async {
                let frames = Self.elementFrames(at: request.point, in: request.window, prepare: prepare)
                let frame = Self.smallestFrame(frames, in: request.window.frame, at: request.point, minimumSize: request.minimumSize)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.running = false
                    if self.requestID == id {
                        if prepare, frame == nil || frame == request.window.frame, self.pending == nil {
                            // 网页首次开启辅助功能后需要一轮更新，静止悬停和快速单击也重试一次。
                            self.pending = request
                        } else { request.completion(frame) }
                    }
                    self.schedule()
                }
            }
        }
    }

    func cancel() {
        requestID += 1
        pending = nil
    }

    nonisolated static func clippedFrame(_ frame: CGRect, to bounds: CGRect, at point: CGPoint, minimumSize: CGFloat) -> CGRect? {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite else { return nil }
        let clipped = frame.intersection(bounds)
        guard clipped.width >= minimumSize, clipped.height >= minimumSize, clipped.contains(point) else { return nil }
        return clipped
    }

    nonisolated static func smallestFrame(_ frames: [CGRect], in bounds: CGRect, at point: CGPoint, minimumSize: CGFloat) -> CGRect? {
        frames.compactMap { clippedFrame($0, to: bounds, at: point, minimumSize: minimumSize) }
            .min { $0.width * $0.height < $1.width * $1.height }
    }

    nonisolated private static func values(of element: AXUIElement) -> [AnyObject]? {
        AXUIElementSetMessagingTimeout(element, 0.04)
        let attributes = [kAXPositionAttribute, kAXSizeAttribute, kAXRoleAttribute, kAXParentAttribute] as CFArray
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &raw) == .success,
              let values = raw as? [AnyObject], values.count == 4 else { return nil }
        return values
    }

    nonisolated private static func frame(from values: [AnyObject]) -> CGRect? {
        guard CFGetTypeID(values[0]) == AXValueGetTypeID(), CFGetTypeID(values[1]) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(values[0] as! AXValue, .cgPoint, &position),
              AXValueGetValue(values[1] as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let frame = CGRect(origin: position, size: size)
        guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else { return nil }
        return frame
    }

    nonisolated private static func children(of element: AXUIElement) -> [AXUIElement] {
        for attribute in [kAXVisibleChildrenAttribute, kAXChildrenAttribute, kAXContentsAttribute] {
            var raw: CFArray?
            if AXUIElementCopyAttributeValues(element, attribute as CFString, 0, 128, &raw) == .success,
               let children = raw as? [AXUIElement], !children.isEmpty { return children }
        }
        return []
    }

    nonisolated private static func elementFrames(at point: CGPoint, in window: SelectionWindow, prepare: Bool) -> [CGRect] {
        // 只查询鼠标下原窗口所属的应用，避免命中轻截自己的全屏遮罩。
        let app = AXUIElementCreateApplication(window.processID)
        AXUIElementSetMessagingTimeout(app, 0.04)
        if prepare {
            // Chromium、Electron 及部分内嵌网页默认不构造完整控件树，按应用请求一次。
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(app, "AXEnhancedUserInterface" as CFString, &settable) == .success, settable.boolValue {
                    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.16
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        if hit == nil || hit.map({ CFEqual($0, app) }) == true {
            var raw: CFArray?
            if AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 32, &raw) == .success,
               let windows = raw as? [AXUIElement] {
                var distance = CGFloat.infinity
                for candidate in windows {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    guard let values = values(of: candidate), let frame = frame(from: values), frame.contains(point) else { continue }
                    let delta = abs(frame.minX - window.frame.minX) + abs(frame.minY - window.frame.minY)
                        + abs(frame.maxX - window.frame.maxX) + abs(frame.maxY - window.frame.maxY)
                    if delta < distance { hit = candidate; distance = delta }
                }
            }
        }
        guard let hit else { return [] }
        var element = hit
        var ancestors: [CGRect] = []
        for _ in 0..<24 {
            guard ProcessInfo.processInfo.systemUptime < deadline, let values = values(of: element) else { break }
            if let frame = frame(from: values) { ancestors.append(frame) }
            if values[2] as? String == kAXWindowRole as String || CFGetTypeID(values[3]) != AXUIElementGetTypeID() { break }
            let parent = values[3] as! AXUIElement
            guard !CFEqual(parent, element) else { break }
            element = parent
        }
        var bounds = window.frame
        var frames: [CGRect] = []
        for frame in ancestors.reversed() {
            if let visible = clippedFrame(frame, to: bounds, at: point, minimumSize: 1) {
                bounds = visible
                frames.append(visible)
            }
        }
        var pending = [(hit, bounds, 0)]
        var visited: [AXUIElement] = []
        var remaining = 128
        // ponytail: 只深入鼠标命中的分支，最多 128 个节点、24 层和约 160 毫秒；超限保留已有结果，扩大规模时再分页并索引节点。
        while let (node, inherited, depth) = pending.popLast() {
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard depth < 24 else { continue }
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            remaining -= 1
            guard let values = values(of: node) else { continue }
            var visible = inherited
            if let frame = frame(from: values) {
                guard let clipped = clippedFrame(frame, to: inherited, at: point, minimumSize: 1) else { continue }
                visible = clipped
                frames.append(clipped)
            }
            for child in children(of: node).reversed() {
                pending.append((child, visible, depth + 1))
            }
        }
        return frames
    }
}
