/// 一块外接显示器对应的规则。
public enum Rule: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 仅外接：关闭内屏
    case externalOnly
    /// 双屏：内屏保持开启
    case both
    /// 不干预：保持现状
    case handsOff

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .externalOnly: "仅外接"
        case .both: "双屏"
        case .handsOff: "不干预"
        }
    }

    /// 多块外接屏同时在线时按「最保守」合并：双屏 > 不干预 > 仅外接
    var priority: Int {
        switch self {
        case .both: 2
        case .handsOff: 1
        case .externalOnly: 0
        }
    }
}

public enum BuiltinState: Sendable, Equatable {
    case on
    case off
    /// 合着盖，内屏本来就不显示
    case lidClosed
    /// 没有内屏（比如台式机），什么都不做
    case missing
}

public struct ExternalDisplay: Sendable, Equatable {
    public var key: String
    public var isVirtual: Bool
    public var isAsleep: Bool
    public var rule: Rule

    public init(key: String, isVirtual: Bool = false, isAsleep: Bool = false, rule: Rule = .externalOnly) {
        self.key = key
        self.isVirtual = isVirtual
        self.isAsleep = isAsleep
        self.rule = rule
    }
}

public enum Decision: Sendable, Equatable {
    case enable(Reason)
    case disable(Reason)
    case leave

    public enum Reason: Sendable, Equatable {
        case noExternal, rule, manual, paused
    }
}

public struct PolicyInput: Sendable {
    public var builtin: BuiltinState
    public var externals: [ExternalDisplay]
    /// 面板里的临时开关：true 开、false 关，nil 表示按规则
    public var manualOverride: Bool?
    /// 反复插拔导致的暂停：期间内屏保持开启
    public var autoDisablePaused: Bool
    public var builtinMirrored: Bool

    public init(builtin: BuiltinState, externals: [ExternalDisplay], manualOverride: Bool? = nil,
                autoDisablePaused: Bool = false, builtinMirrored: Bool = false) {
        self.builtin = builtin
        self.externals = externals
        self.manualOverride = manualOverride
        self.autoDisablePaused = autoDisablePaused
        self.builtinMirrored = builtinMirrored
    }
}

/// 纯函数：给定当前显示器情况，算出内屏应该开、关还是不动。
public enum Policy {
    public static func decide(_ input: PolicyInput) -> Decision {
        switch input.builtin {
        case .missing, .lidClosed: return .leave
        case .on, .off: break
        }

        // 真正能显示画面的外接屏：实体、且没有休眠
        let real = input.externals.filter { !$0.isVirtual && !$0.isAsleep }
        // 不变量：没有能用的外接屏，内屏就必须亮着
        if real.isEmpty { return .enable(.noExternal) }

        if let on = input.manualOverride { return on ? .enable(.manual) : .disable(.manual) }
        if input.autoDisablePaused { return .enable(.paused) }
        if input.builtinMirrored { return .leave }

        // 虚拟屏一律按「不干预」参与合并；休眠的外接屏不参与
        let considered = input.externals.filter { $0.isVirtual || !$0.isAsleep }
        let merged = considered
            .map { $0.isVirtual ? Rule.handsOff : $0.rule }
            .max { $0.priority < $1.priority } ?? .externalOnly

        switch merged {
        case .both: return .enable(.rule)
        case .handsOff: return .leave
        case .externalOnly: return .disable(.rule)
        }
    }
}
