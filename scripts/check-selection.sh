#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${PROJECT_DIR}/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_DIR}/.build/swift-cache"
# --show-bin-path 不触发编译，全新检出的环境必须先真正构建出模块。
swift build --package-path "${PROJECT_DIR}" -c release --arch arm64 --disable-sandbox
BIN_DIR="$(swift build --package-path "${PROJECT_DIR}" -c release --arch arm64 --show-bin-path)"
# 新旧 SwiftPM 产物布局：模块可能在 Modules/ 或产物目录本身，CaptureCore 可能是逐文件对象或单个 CaptureCore.o。
MODULE_DIR="${BIN_DIR}/Modules"; [[ -d "${MODULE_DIR}" ]] || MODULE_DIR="${BIN_DIR}"
CORE_OBJECTS=("${BIN_DIR}"/CaptureCore.build/*.swift.o(N)); (( ${#CORE_OBJECTS} )) || CORE_OBJECTS=("${BIN_DIR}/CaptureCore.o")
cat > "${PROJECT_DIR}/.build/SelectionCheck.swift" <<'SWIFT'
import AppKit
import CaptureCore

@main
struct SelectionCheck {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let image = try ImageCodec.context(width: 1600, height: 1200).makeImage()!
        let display = CGRect(x: -800, y: -600, width: 800, height: 600)
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        precondition(!SelectionWindow.isSelectable(frame: display, layer: dockLayer, displays: [display]),
                     "Dock 的整屏透明宿主不得拦截后面的应用窗口")
        precondition(!SelectionWindow.isSelectable(frame: display, layer: dockLayer + 1, displays: [display]),
                     "通知中心的整屏透明宿主不得拦截后面的应用窗口")
        precondition(SelectionWindow.isSelectable(frame: display, layer: 0, displays: [display]),
                     "普通全屏应用必须保留")
        precondition(SelectionWindow.isSelectable(frame: CGRect(x: -600, y: -600, width: 300, height: 100), layer: Int(Int32.max) - 18, displays: [display]),
                     "Alcove 等局部高层面板必须保留")
        precondition(!SelectionWindow.isSelectable(frame: CGRect(x: -900, y: -700, width: 2000, height: 1400), layer: dockLayer, displays: [display]),
                     "跨屏透明宿主也不得拦截应用窗口")
        let front = SelectionWindow(id: 1, processID: 0, frame: CGRect(x: -720, y: -560, width: 160, height: 140))
        let back = SelectionWindow(id: 2, processID: 0, frame: CGRect(x: -860, y: -640, width: 900, height: 760))
        let view = SelectionView(image: image, displayFrame: display, candidates: [front, back], long: false)
        let window = CaptureOverlayWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        var completed = false
        var result: CGRect?
        view.finished = { completed = true; result = $0 }

        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in target: NSView, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: target.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let point = CGPoint(x: 100, y: 80)
        let expected = CGRect(x: 80, y: 40, width: 160, height: 140)
        view.preview(at: CGPoint(x: 20, y: 20))
        precondition(view.selection == view.bounds, "跨屏窗口应裁切到当前屏幕")
        view.preview(at: point)
        precondition(view.selection == expected, "应优先定位最上层窗口，并正确转换负坐标屏幕")
        let firstControl = CGRect(x: -710, y: -535, width: 30, height: 30)
        view.applyHoverResult(firstControl, in: front, at: point)
        let firstSelection = view.selection
        let nextPoint = CGPoint(x: 150, y: 80)
        view.preview(at: nextPoint)
        precondition(view.selection == firstSelection,
                     "离开控件等待新结果时不得先放大到窗口")
        view.applyHoverResult(front.frame, in: front, at: point)
        precondition(view.selection == firstSelection, "旧位置返回的窗口范围不得使遮罩闪回整个窗口")
        let nextControl = CGRect(x: -660, y: -535, width: 30, height: 30)
        view.applyHoverResult(nextControl, in: front, at: nextPoint)
        precondition(view.selection == CGRect(x: 140, y: 65, width: 30, height: 30), "新控件结果应直接替换旧控件")
        view.applyHoverResult(nextControl, in: front, at: nextPoint)
        precondition(view.selection == CGRect(x: 140, y: 65, width: 30, height: 30), "重复命中同一控件应保留原选区")
        view.preview(at: point)
        view.applyHoverResult(front.frame, in: front, at: point)
        view.mouseDown(with: mouse(.leftMouseDown, point, in: view))
        view.preview(at: CGPoint(x: 400, y: 400))
        precondition(view.selection == expected, "按下后悬停查询不得改变选区")
        let jitter = CGPoint(x: 101, y: 81)
        view.mouseDragged(with: mouse(.leftMouseDragged, jitter, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, jitter, in: view))
        precondition(completed && result == expected, "轻微抖动的单击应确认智能选区")

        completed = false
        let start = CGPoint(x: 240, y: 180)
        view.mouseDown(with: mouse(.leftMouseDown, start, in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 40, y: 20), in: view))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 30, y: 15), in: view))
        precondition(completed && result == CGRect(x: 30, y: 15, width: 210, height: 165), "反向拖动应覆盖智能选区，并使用松开时的终点")
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 20), in: view))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: -100, y: 800), in: view))
        precondition(result == CGRect(x: 0, y: 20, width: 20, height: 580), "拖出屏幕的手动选区应裁切到屏幕边界")

        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        precondition(result == nil, "Escape 应取消截图")
        window.cancelAction = { [weak view] in view?.cancelOperation(nil) }
        completed = false
        window.sendEvent(mouse(.rightMouseDown, point, in: view))
        precondition(completed && result == nil, "右键与触摸板双指辅助点按应取消截图")
        completed = false
        window.sendEvent(mouse(.leftMouseDown, point, in: view, modifiers: .control))
        precondition(completed && result == nil, "Control 点按应沿用系统的辅助点按行为")
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        view.keyDown(with: space)
        precondition(result == view.bounds, "空格应选择当前屏幕")

        let long = SelectionView(image: image, displayFrame: display, candidates: [front, back], long: true)
        window.contentView = long
        completed = false
        long.finished = { completed = true; result = $0 }
        long.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 300), in: long))
        long.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 350, y: 350), in: long))
        precondition(!completed, "长截图不得确认过小的区域")
        long.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 20), in: long))
        long.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 130, y: 130), in: long))
        precondition(completed && result == CGRect(x: 20, y: 20, width: 110, height: 110), "长截图应保留有效手动框选")
        completed = false
        window.cancelAction = { [weak long] in long?.cancelOperation(nil) }
        window.sendEvent(mouse(.rightMouseDown, point, in: long))
        precondition(completed && result == nil, "长截图选区也应支持右键取消")
        window.cancelAction = nil

        let element = CGRect(x: -750, y: -580, width: 300, height: 200)
        let globalPoint = CGPoint(x: -700, y: -520)
        precondition(ElementLocator.clippedFrame(element, to: front.frame, at: globalPoint, minimumSize: 3) == front.frame, "元素边界不得超出所在窗口")
        precondition(ElementLocator.clippedFrame(element, to: front.frame, at: .zero, minimumSize: 3) == nil, "不得接受鼠标未命中的元素")
        precondition(ElementLocator.clippedFrame(CGRect(x: -710, y: -540, width: 30, height: 30), to: front.frame, at: globalPoint, minimumSize: 100) == nil, "长截图应跳过过小控件")
        precondition(ElementLocator.clippedFrame(CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), to: display, at: .zero, minimumSize: 3) == nil, "无效辅助功能坐标应被拒绝")
        let buttonFrame = CGRect(x: -710, y: -535, width: 45, height: 24)
        let hierarchy = [back.frame, front.frame, buttonFrame, CGRect(x: -600, y: -535, width: 20, height: 20)]
        precondition(ElementLocator.smallestFrame(hierarchy, in: front.frame, at: globalPoint, minimumSize: 3) == buttonFrame,
                     "容器与子控件同时命中时应选中按钮，不能退回整个窗口或命中旁边的控件")
        precondition(ElementLocator.smallestFrame(hierarchy, in: front.frame, at: globalPoint, minimumSize: 100) == front.frame,
                     "长截图跳过小按钮时应保留有效父容器")
        precondition(ElementLocator.smallestFrame([buttonFrame], in: front.frame, at: globalPoint, minimumSize: 3) == buttonFrame,
                     "父节点读取不完整时仍应保留已经得到的子控件范围")

        precondition(window.styleMask.contains(.nonactivatingPanel) && !window.canBecomeMain && !window.hidesOnDeactivate,
                     "截图浮层应接收按键但不激活应用，也不能随原应用切换而消失")
        let backdrop = EditorBackdrop(frame: view.bounds)
        backdrop.background = image
        backdrop.selection = CGRect(x: 100, y: 120, width: 300, height: 220)
        let content = NSView(frame: backdrop.selection)
        backdrop.addSubview(content)
        window.contentView = backdrop
        var adjusting = false
        var changes = 0
        backdrop.resizing = { adjusting = $0 }
        backdrop.resizeFinished = { result = $0; changes += 1; backdrop.resizing?(false) }
        func hit(_ point: CGPoint) -> NSView? { backdrop.hitTest(backdrop.convert(point, to: backdrop.superview)) }
        precondition(hit(CGPoint(x: 150, y: 170)) === backdrop, "移动模式应能拖动选区内部")
        precondition(hit(CGPoint(x: 170, y: 121)) === backdrop, "整条边缘都应可缩放，不限于中点手柄")
        backdrop.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 170), in: backdrop))
        backdrop.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 151, y: 170), in: backdrop))
        precondition(changes == 0 && !adjusting, "普通点击不应触发重新裁切或隐藏工具栏")
        backdrop.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 170), in: backdrop))
        backdrop.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 190, y: 205), in: backdrop))
        precondition(adjusting && backdrop.selection == CGRect(x: 140, y: 155, width: 300, height: 220), "拖动期间应实时预览选区位置")
        backdrop.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 200, y: 215), in: backdrop))
        precondition(result == CGRect(x: 150, y: 165, width: 300, height: 220) && !adjusting, "选区移动应保持尺寸并采用松开时的位置")
        backdrop.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 220, y: 230), in: backdrop))
        backdrop.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: -900, y: -900), in: backdrop))
        precondition(result == CGRect(x: 0, y: 0, width: 300, height: 220), "选区移动不得越出屏幕或改变大小")

        backdrop.selection = CGRect(x: 100, y: 100, width: 300, height: 200)
        backdrop.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 170, y: 100), in: backdrop))
        backdrop.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 170, y: 70), in: backdrop))
        precondition(result == CGRect(x: 100, y: 70, width: 300, height: 230), "拖动上边缘应只调整高度")
        backdrop.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 170, y: 75), in: backdrop))
        backdrop.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 170, y: 85), in: backdrop))
        precondition(result == CGRect(x: 100, y: 80, width: 300, height: 220), "从边缘热区拖动时不能跳到鼠标的偏移位置")
        backdrop.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 300), in: backdrop))
        backdrop.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 1000, y: 900), in: backdrop))
        precondition(result == CGRect(x: 100, y: 80, width: 700, height: 520), "角点放大应同时调整宽高并限制在屏幕内")
        backdrop.selection = CGRect(x: 100, y: 100, width: 300, height: 200)
        backdrop.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100), in: backdrop))
        backdrop.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 600, y: 500), in: backdrop))
        precondition(result == CGRect(x: 397, y: 297, width: 3, height: 3), "缩小不得产生反向或零尺寸选区")

        backdrop.selection = content.frame
        backdrop.allowsMove = { _ in false }
        precondition(hit(CGPoint(x: 180, y: 190)) === content, "命中标注时不得移动整个选区")
        let strip = ToolStrip()
        let button = ToolButton(symbol: "checkmark", label: "检查按钮", target: nil, action: nil)
        strip.add(button)
        strip.frame.origin = CGPoint(x: 100, y: 100)
        backdrop.addSubview(strip)
        precondition(hit(CGPoint(x: 115, y: 122)) === button, "工具栏与选区重叠时应优先响应按钮")

        let document = try ImageDocument(width: 400)
        try document.append(image.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 300))!)
        let canvas = AnnotationCanvas(document: document)
        window.contentView = canvas
        canvas.scale = 1
        canvas.annotationOrigin = CGPoint(x: 100, y: 60)
        precondition(canvas.tool == 0, "截图后必须默认使用移动工具")
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 30), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 100, y: 90), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 100, y: 90), in: canvas))
        precondition(canvas.annotations.isEmpty, "移动模式不得默认画出矩形")
        canvas.tool = 1
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 30), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 100, y: 90), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 100, y: 90), in: canvas))
        precondition(canvas.annotations.count == 1 && canvas.annotations[0].start == CGPoint(x: 120, y: 90), "标注应保留原始截图坐标")
        if canvas.history.groupingLevel > 0 { canvas.history.endUndoGrouping() }
        let nextDocument = try ImageDocument(width: 300)
        try nextDocument.append(image.cropping(to: CGRect(x: 140, y: 80, width: 300, height: 200))!)
        canvas.document = nextDocument
        canvas.annotationOrigin = CGPoint(x: 140, y: 80)
        precondition(canvas.exportAnnotations[0].start == CGPoint(x: -20, y: 10) && canvas.exportAnnotations[0].end == CGPoint(x: 60, y: 70),
                     "移动选区后导出的标注必须按新裁切原点换算")
        precondition(canvas.annotation(atViewPoint: CGPoint(x: 60, y: 40)) == 0, "调整选区后仍应能选中标注")
        canvas.history.undo()
        precondition(canvas.annotations.isEmpty, "调整选区后撤销历史不得丢失")
        canvas.history.redo()
        precondition(canvas.annotations.count == 1 && canvas.annotations[0].start == CGPoint(x: 120, y: 90), "调整选区后重做应保留原始标注位置")
        let pixels = CaptureRegion.pixelRect(for: CGRect(x: 20, y: 30, width: 100, height: 80), image: image, screenSize: CGSize(width: 800, height: 600))
        precondition(pixels == CGRect(x: 40, y: 60, width: 200, height: 160), "裁切与调整应使用一致的 Retina 像素坐标")

        if !NSScreen.screens.isEmpty {
            let editor = EditorWindow(document: document)
            let editorBackdrop = editor.window!.contentView as! EditorBackdrop
            let editorCanvas = editorBackdrop.subviews.compactMap { $0 as? NSScrollView }.first!.documentView as! AnnotationCanvas
            let buttons = editorBackdrop.subviews.compactMap { $0 as? ToolStrip }.flatMap { $0.subviews.compactMap { $0 as? ToolButton } }
            precondition(editorCanvas.tool == 0 && buttons.first { $0.tag == 0 && $0.toolTip == "移动选区与选择标注" }!.chosen,
                         "实际编辑器与工具栏的默认工具必须一致")
            var dismissed = false
            editor.onClose = { dismissed = true }
            let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            editor.window!.sendEvent(rightClick)
            precondition(dismissed && editor.window!.contentView == nil, "标注界面右键取消应释放编辑器，而不依赖焦点位于画布")
        } else {
            print("当前检查进程没有可见显示器，实际编辑器窗口检查需在桌面终端运行。")
        }
        window.contentView = nil
        window.close()
        print("选区逻辑检查通过：嵌套控件定位、Esc 与辅助点按取消、默认移动、边角缩放、拖动预览、屏幕边界、工具栏点击、标注导出与撤销、不激活应用的浮层配置。")
    }
}
SWIFT
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    -module-cache-path "${CLANG_MODULE_CACHE_PATH}" -I "${MODULE_DIR}" \
    "${PROJECT_DIR}/Sources/LightSnap/CaptureService.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/ElementLocator.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/FloatingTools.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/AnnotationCanvas.swift" \
    "${PROJECT_DIR}/Sources/LightSnap/FloatingEditor.swift" \
    "${PROJECT_DIR}/.build/SelectionCheck.swift" \
    "${CORE_OBJECTS[@]}" -o "${PROJECT_DIR}/.build/check-selection"
"${PROJECT_DIR}/.build/check-selection"
