import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let modifier = NSPopUpButton()
    private let normal = NSPopUpButton()
    private let long = NSPopUpButton()
    private let login = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "快捷键冲突时请更换组合。")
    private let selectionStatus = NSTextField(wrappingLabelWithString: "")
    var changed: (() -> Bool)?
    private let keys: [(String, UInt32)] = [("A", 0), ("S", 1), ("D", 2), ("F", 3), ("G", 5), ("Q", 12), ("W", 13), ("E", 14), ("R", 15), ("1", 18), ("2", 19), ("3", 20)]
    private let modifiers: [UInt32] = [UInt32(controlKey), UInt32(controlKey | optionKey), UInt32(cmdKey | shiftKey), UInt32(cmdKey | optionKey)]

    init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 470, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "轻截设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        modifier.addItems(withTitles: ["⌃ Control", "⌃⌥ Control + Option", "⌘⇧ Command + Shift", "⌘⌥ Command + Option"])
        normal.addItems(withTitles: keys.map(\.0))
        long.addItems(withTitles: keys.map(\.0))
        let defaults = UserDefaults.standard
        modifier.selectItem(at: modifiers.firstIndex(of: defaults.object(forKey: "hotkeyModifier") as? UInt32 ?? HotKeys.defaultModifier) ?? 0)
        normal.selectItem(at: keys.firstIndex(where: { $0.1 == (defaults.object(forKey: "hotkeyNormal") as? UInt32 ?? HotKeys.defaultNormal) }) ?? 0)
        long.selectItem(at: keys.firstIndex(where: { $0.1 == (defaults.object(forKey: "hotkeyLong") as? UInt32 ?? HotKeys.defaultLong) }) ?? 1)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        login.action = #selector(toggleLogin)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "修饰键"), modifier], [NSTextField(labelWithString: "区域截图"), normal], [NSTextField(labelWithString: "长截图"), long]])
        grid.rowSpacing = 14
        grid.columnSpacing = 18
        let apply = NSButton(title: "应用快捷键", target: self, action: #selector(applyKeys))
        refreshSelectionStatus()
        selectionStatus.font = .systemFont(ofSize: 12)
        selectionStatus.textColor = .secondaryLabelColor
        let permission = NSButton(title: "设置元素定位权限…", target: self, action: #selector(openAccessibilitySettings))
        let stack = NSStackView(views: [grid, apply, login, message, selectionStatus, permission])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        selectionStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        }
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档初始化") }
    func windowDidBecomeKey(_ notification: Notification) { refreshSelectionStatus() }
    private func refreshSelectionStatus() {
        selectionStatus.stringValue = AXIsProcessTrusted()
            ? "智能选区：已允许识别窗口内控件。截图时悬停定位、单击选中，拖动可手动框选。"
            : "智能选区：窗口定位已可用。允许辅助功能后，还可识别按钮、列表和内容区域。"
    }
    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func applyKeys() {
        guard normal.indexOfSelectedItem != long.indexOfSelectedItem else { message.stringValue = "两个快捷键不能相同。"; return }
        let defaults = UserDefaults.standard
        defaults.set(modifiers[modifier.indexOfSelectedItem], forKey: "hotkeyModifier")
        defaults.set(keys[normal.indexOfSelectedItem].1, forKey: "hotkeyNormal")
        defaults.set(keys[long.indexOfSelectedItem].1, forKey: "hotkeyLong")
        message.stringValue = changed?() == true ? "快捷键已应用。" : "部分快捷键被占用，请更换组合后重试。"
    }
    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message.stringValue = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置的登录项中允许轻截启动。" : "登录启动设置已更新。"
        } catch {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            message.stringValue = "设置失败：\(error.localizedDescription)"
        }
    }
}
