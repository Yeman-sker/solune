import AppKit
import CoreGraphics
import IOKit
import SoluneCore

/// 唯一碰私有接口的地方。系统更新导致接口失效时，只需要改这个文件。
enum DisplayAPI {
    typealias ConfigureFn = @convention(c) (OpaquePointer?, CGDirectDisplayID, Bool) -> CGError
    typealias ListFn = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    nonisolated(unsafe) private static let handle = dlopen(nil, RTLD_NOW)
    /// 启用 / 断开一块显示器
    static let configure: ConfigureFn? = symbol("CGSConfigureDisplayEnabled") ?? symbol("SLSConfigureDisplayEnabled")
    /// 列出所有显示器，包括已经被断开的（公开接口看不到断开的内屏）
    private static let listAll: ListFn? = symbol("CGSGetDisplayList") ?? symbol("SLSGetDisplayList")

    private static func symbol<T>(_ name: String) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static func setEnabled(_ id: CGDirectDisplayID, _ on: Bool) -> Bool {
        guard let configure else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard configure(config, id, on) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        // 只在本次登录会话有效：重启或注销后系统自动恢复所有屏幕
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    static func allDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        if let listAll, listAll(32, &ids, &n) == .success { return Array(ids.prefix(Int(n))) }
        return onlineDisplayIDs()
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    static func builtinID() -> CGDirectDisplayID? {
        allDisplayIDs().first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }
}

struct ExternalInfo: Equatable {
    let id: CGDirectDisplayID
    /// 厂商 + 型号 + 序列号（来自 EDID），规则按这个记
    let key: String
    let name: String
    let isVirtual: Bool
    let isAsleep: Bool
}

struct DisplaySnapshot {
    var builtin: BuiltinState
    var externals: [ExternalInfo]
    var builtinMirrored: Bool

    /// 真正能显示画面的外接屏
    var realExternals: [ExternalInfo] { externals.filter { !$0.isVirtual && !$0.isAsleep } }
}

@MainActor
final class DisplayController {
    let dryRun: Bool
    private(set) var builtinID: CGDirectDisplayID?
    /// 演练模式下假装的内屏状态
    private var simulatedOn: Bool?
    private var nameCache: [String: String] = [:]

    init(dryRun: Bool) {
        self.dryRun = dryRun
        builtinID = DisplayAPI.builtinID()
    }

    var hasAPI: Bool { DisplayAPI.configure != nil }
    var canControl: Bool { hasAPI && builtinID != nil }

    func snapshot() -> DisplaySnapshot {
        if builtinID == nil { builtinID = DisplayAPI.builtinID() }

        let panels = Self.physicalPanels()
        let screenNames = Self.screenNames()
        var externals: [ExternalInfo] = []
        for id in DisplayAPI.onlineDisplayIDs() where CGDisplayIsBuiltin(id) == 0 {
            let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
            let key = String(format: "%04x-%04x-%08x", vendor, model, CGDisplaySerialNumber(id))
            let panel = panels?.first { $0.vendor == vendor && $0.model == model }
            let isVirtual = panels.map { _ in panel == nil } ?? Self.looksVirtual(screenNames[id] ?? "")
            let name = screenNames[id] ?? panel?.name ?? nameCache[key] ?? (isVirtual ? "虚拟显示器" : "外接显示器")
            nameCache[key] = name
            externals.append(ExternalInfo(id: id, key: key, name: name, isVirtual: isVirtual,
                                          isAsleep: CGDisplayIsAsleep(id) != 0))
        }

        let builtin: BuiltinState
        if let b = builtinID {
            if DisplayAPI.lidClosed() {
                builtin = .lidClosed
            } else if let simulatedOn {
                builtin = simulatedOn ? .on : .off
            } else {
                builtin = CGDisplayIsOnline(b) != 0 && CGDisplayIsActive(b) != 0 ? .on : .off
            }
        } else {
            builtin = .missing
        }
        let mirrored = builtinID.map { CGDisplayIsInMirrorSet($0) != 0 } ?? false
        return DisplaySnapshot(builtin: builtin, externals: externals, builtinMirrored: mirrored)
    }

    @discardableResult
    func setBuiltin(_ on: Bool) -> Bool {
        guard let id = builtinID, hasAPI else { return false }
        if !on {
            // 不变量：必须还有一块正在显示的实体外接屏，否则拒绝
            guard snapshot().realExternals.contains(where: { CGDisplayIsActive($0.id) != 0 }) else { return false }
        }
        if dryRun {
            simulatedOn = on
            return true
        }
        return DisplayAPI.setEnabled(id, on)
    }

    // MARK: - 识别实体显示器

    struct Panel {
        let vendor: UInt32
        let model: UInt32
        let name: String
    }

    /// Apple 芯片上每块实体外接屏都挂在一个显示控制器下面，虚拟屏（随航、AirPlay、DisplayLink、虚拟屏软件）没有。
    /// 返回 nil 表示这台机器上查不到（比如 Intel Mac），改用名字判断。
    static func physicalPanels() -> [Panel]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var found = false
        var panels: [Panel] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            found = true
            if (property(service, "external") as? Bool) == true,
               let attrs = property(service, "DisplayAttributes") as? [String: Any],
               let product = attrs["ProductAttributes"] as? [String: Any],
               let vendor = product["LegacyManufacturerID"] as? Int,
               let model = product["ProductID"] as? Int {
                panels.append(Panel(vendor: UInt32(vendor), model: UInt32(model), name: product["ProductName"] as? String ?? ""))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return found ? panels : nil
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[n.uint32Value] = screen.localizedName
            }
        }
        return names
    }

    private static func looksVirtual(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["sidecar", "airplay", "virtual", "dummy", "displaylink", "随航", "虚拟"].contains { n.contains($0) }
    }
}
