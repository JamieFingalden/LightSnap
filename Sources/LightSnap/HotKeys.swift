import AppKit
import Carbon

@MainActor
final class HotKeys {
    static let defaultModifier = UInt32(controlKey)
    static let defaultNormal = UInt32(kVK_ANSI_1)
    static let defaultLong = UInt32(kVK_ANSI_2)
    static let defaultRecording = UInt32(kVK_ANSI_3)
    static let defaultPause = UInt32(kVK_ANSI_4)
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    var action: ((UInt32) -> Void)?

    func register() -> Bool {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr else { return status }
                let owner = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { owner.action?(identifier.id) }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let defaults = UserDefaults.standard
        // 将旧版快捷键迁移到用户指定的组合，之后保留设置窗口中的自定义修改。
        if !defaults.bool(forKey: "controlNumberShortcutsMigrated") {
            defaults.set(Self.defaultModifier, forKey: "hotkeyModifier")
            defaults.set(Self.defaultNormal, forKey: "hotkeyNormal")
            defaults.set(Self.defaultLong, forKey: "hotkeyLong")
            defaults.set(true, forKey: "controlNumberShortcutsMigrated")
        }
        let modifier = defaults.object(forKey: "hotkeyModifier") as? UInt32 ?? Self.defaultModifier
        let normal = defaults.object(forKey: "hotkeyNormal") as? UInt32 ?? Self.defaultNormal
        let long = defaults.object(forKey: "hotkeyLong") as? UInt32 ?? Self.defaultLong
        let recording = defaults.object(forKey: "hotkeyRecording") as? UInt32 ?? Self.defaultRecording
        let pause = defaults.object(forKey: "hotkeyPauseRecording") as? UInt32 ?? Self.defaultPause
        var success = handler != nil
        for (index, code) in [normal, long, recording, pause].enumerated() {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(code, modifier, EventHotKeyID(signature: 0x4C534E50, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { references.append(reference) }
            else { success = false }
        }
        return success
    }
}
