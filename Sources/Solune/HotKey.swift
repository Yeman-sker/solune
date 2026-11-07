import Carbon.HIToolbox
import Foundation

/// 全局快捷键 ⌃⌥⌘D。用 Carbon 注册，不需要辅助功能权限。
@MainActor
enum HotKey {
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: 0x534F_4C4E, id: 1) // 'SOLN'
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}
