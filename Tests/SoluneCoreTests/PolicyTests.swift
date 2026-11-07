import Testing
@testable import SoluneCore

/// 对应 DESIGN.md 里的规则和边界条件表。
struct PolicyTests {
    private func decide(_ builtin: BuiltinState, _ externals: [ExternalDisplay], manual: Bool? = nil,
                        paused: Bool = false, mirrored: Bool = false) -> Decision {
        Policy.decide(PolicyInput(builtin: builtin, externals: externals, manualOverride: manual,
                                  autoDisablePaused: paused, builtinMirrored: mirrored))
    }

    @Test("没有外接屏：内屏必须亮（E1、E2）")
    func noExternalEnables() {
        #expect(decide(.off, []) == .enable(.noExternal))
        #expect(decide(.on, []) == .enable(.noExternal))
    }

    @Test("仅外接规则：关闭内屏")
    func externalOnlyDisables() {
        #expect(decide(.on, [ExternalDisplay(key: "a", rule: .externalOnly)]) == .disable(.rule))
    }

    @Test("双屏规则：保持内屏")
    func bothKeepsBuiltin() {
        #expect(decide(.off, [ExternalDisplay(key: "a", rule: .both)]) == .enable(.rule))
    }

    @Test("不干预规则：不动")
    func handsOffLeaves() {
        #expect(decide(.on, [ExternalDisplay(key: "a", rule: .handsOff)]) == .leave)
        #expect(decide(.off, [ExternalDisplay(key: "a", rule: .handsOff)]) == .leave)
    }

    @Test("多块外接屏按最保守合并：双屏 > 不干预 > 仅外接")
    func mergeIsConservative() {
        let only = ExternalDisplay(key: "a", rule: .externalOnly)
        #expect(decide(.on, [only, ExternalDisplay(key: "b", rule: .both)]) == .enable(.rule))
        #expect(decide(.on, [only, ExternalDisplay(key: "b", rule: .handsOff)]) == .leave)
        #expect(decide(.on, [only, ExternalDisplay(key: "b", rule: .externalOnly)]) == .disable(.rule))
    }

    @Test("只有虚拟屏（随航、AirPlay）：内屏必须亮")
    func virtualOnlyEnables() {
        #expect(decide(.off, [ExternalDisplay(key: "v", isVirtual: true)]) == .enable(.noExternal))
    }

    @Test("虚拟屏和实体屏同时在线：按不干预合并")
    func virtualCountsAsHandsOff() {
        let real = ExternalDisplay(key: "a", rule: .externalOnly)
        #expect(decide(.on, [real, ExternalDisplay(key: "v", isVirtual: true)]) == .leave)
    }

    @Test("外接屏自己休眠：当成没有外接屏，立即亮内屏（E7）")
    func asleepExternalEnables() {
        #expect(decide(.off, [ExternalDisplay(key: "a", isAsleep: true)]) == .enable(.noExternal))
    }

    @Test("合盖或没有内屏：不动（E5）")
    func lidClosedLeaves() {
        #expect(decide(.lidClosed, []) == .leave)
        #expect(decide(.lidClosed, [ExternalDisplay(key: "a")]) == .leave)
        #expect(decide(.missing, []) == .leave)
    }

    @Test("临时开关优先于规则，但不能关掉唯一的屏幕")
    func manualOverride() {
        let both = ExternalDisplay(key: "a", rule: .both)
        #expect(decide(.on, [both], manual: false) == .disable(.manual))
        #expect(decide(.off, [ExternalDisplay(key: "a")], manual: true) == .enable(.manual))
        #expect(decide(.on, [], manual: false) == .enable(.noExternal))
    }

    @Test("反复插拔暂停期间：保持内屏开启（E13）")
    func flapPauseKeepsBuiltin() {
        #expect(decide(.on, [ExternalDisplay(key: "a")], paused: true) == .enable(.paused))
    }

    @Test("内屏在镜像中：不动")
    func mirroredLeaves() {
        #expect(decide(.on, [ExternalDisplay(key: "a")], mirrored: true) == .leave)
    }
}
