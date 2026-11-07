import AppKit
import os
import SoluneCore

let log = Logger(subsystem: "local.solune", category: "displays")

/// 可取消的一次性延时。
@MainActor
final class Delay {
    private var task: Task<Void, Never>?
    private(set) var fireDate: Date?
    var isPending: Bool { task != nil }

    func schedule(after seconds: Double, _ body: @escaping @MainActor () -> Void) {
        cancel()
        fireDate = Date().addingTimeInterval(seconds)
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.fireDate = nil
            body()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        fireDate = nil
    }
}

/// 调度器：收集事件，按规则决定什么时候开关内屏。
/// 非对称防抖（开得快、关得稳）、唤醒稳定期、反复插拔保护、执行后校验都在这里。
@MainActor
final class Reconciler {
    private static weak var current: Reconciler?

    private let displays: DisplayController
    private let settings: Settings
    private let model: AppModel

    /// 状态变化时通知菜单栏图标：(新状态, 是否接着实体外接屏)
    var onPhase: ((Phase, Bool) -> Void)?
    /// 内屏刚被关掉：用来启动看门狗
    var onBuiltinDisabled: ((CGDirectDisplayID) -> Void)?

    private var userPaused = false { didSet { model.userPaused = userPaused } }
    private var failed = false
    private var flapUntil: Date?
    private var disableLog: [Date] = []
    private var stabilizeUntil: Date?
    private var systemAsleep = false
    private var screensAsleep = false
    private var lastSignature: Set<String>?
    private var pendingSignature: Set<String>?
    private var verifyAttempts = 0
    private var didApply = false
    private var lastPhase: Phase?
    private var lastHasExternal = false
    private var observers: [NSObjectProtocol] = []

    private let coalesce = Delay()
    private let disableTimer = Delay()
    private let stabilizeTimer = Delay()
    private let flapTimer = Delay()
    private let verifyTimer = Delay()

    init(displays: DisplayController, settings: Settings, model: AppModel) {
        self.displays = displays
        self.settings = settings
        self.model = model
    }

    func start() {
        Reconciler.current = self
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { Reconciler.current?.displaysChanged() } }
        }, nil)

        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.willSleepNotification) { $0.systemWillSleep() }
        observe(center, NSWorkspace.didWakeNotification) { $0.systemDidWake() }
        observe(center, NSWorkspace.screensDidSleepNotification) { $0.screensSleep(true) }
        observe(center, NSWorkspace.screensDidWakeNotification) { $0.screensSleep(false) }

        model.defaultRule = settings.defaultRule
        evaluate("启动")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Reconciler) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { body(self) }
            }
        })
    }

    // MARK: - 事件

    private func displaysChanged() {
        // 一次插拔会连续触发好几次回调，合并成一次
        coalesce.schedule(after: 0.08) { [weak self] in self?.evaluate("显示器变化") }
    }

    private func systemWillSleep() {
        systemAsleep = true
        disableTimer.cancel()
        coalesce.cancel()
    }

    private func systemDidWake() {
        systemAsleep = false
        screensAsleep = false
        // E3：外接屏唤醒有延迟，3 秒内不来回切换
        stabilizeUntil = Date().addingTimeInterval(3)
        stabilizeTimer.schedule(after: 3) { [weak self] in
            self?.stabilizeUntil = nil
            self?.evaluate("唤醒稳定期结束")
        }
        evaluate("唤醒")
    }

    private func screensSleep(_ asleep: Bool) {
        screensAsleep = asleep
        if asleep { disableTimer.cancel() } else { evaluate("亮屏") }
    }

    // MARK: - 面板操作

    func setRule(_ rule: Rule, for key: String) {
        settings.setRule(rule, for: key)
        evaluate("修改规则")
    }

    func setDefaultRule(_ rule: Rule) {
        settings.defaultRule = rule
        model.defaultRule = rule
        evaluate("修改默认规则")
    }

    func setBuiltinManually(_ on: Bool) {
        model.manualOverride = on
        evaluate("手动开关")
    }

    func setPaused(_ paused: Bool) {
        userPaused = paused
        if !paused { clearFailure() }
        evaluate(paused ? "暂停" : "恢复")
    }

    func retry() {
        clearFailure()
        evaluate("重试")
    }

    /// ⌃⌥⌘D：立即恢复内屏，并在本次会话暂停自动管理
    func emergencyRestore() {
        userPaused = true
        model.manualOverride = nil
        disableTimer.cancel()
        if displays.snapshot().builtin == .off { apply(on: true, reason: "紧急快捷键") }
        evaluate("紧急快捷键")
    }

    /// App 退出前：把内屏打开
    func restoreForQuit() {
        disableTimer.cancel()
        if displays.snapshot().builtin == .off { displays.setBuiltin(true) }
    }

    private func clearFailure() {
        failed = false
        verifyAttempts = 0
        model.problem = nil
    }

    // MARK: - 核心

    private var isStabilizing: Bool { (stabilizeUntil ?? .distantPast) > Date() }
    private var isFlapPaused: Bool { (flapUntil ?? .distantPast) > Date() }

    private func evaluate(_ reason: String, fromTimer: Bool = false) {
        didApply = false
        let snap = displays.snapshot()
        let real = snap.realExternals
        let signature = Set(real.map { "\($0.id)/\($0.key)" })
        if let last = lastSignature, last != signature {
            model.manualOverride = nil // 显示器有变化：临时开关失效
        }
        lastSignature = signature
        publish(snap)
        defer { updatePhase(didApply ? displays.snapshot() : snap) }

        guard displays.canControl else { return }
        guard !systemAsleep, !screensAsleep else { return } // E8：息屏期间先不动，亮屏后统一处理

        let mustEnable = real.isEmpty && snap.builtin == .off
        if failed || userPaused || isStabilizing {
            disableTimer.cancel()
            if mustEnable {
                apply(on: true, reason: "\(reason)：没有外接屏")
            } else if let on = model.manualOverride, !failed, !isStabilizing {
                if on, snap.builtin == .off { apply(on: true, reason: "手动") }
                if !on, snap.builtin == .on { apply(on: false, reason: "手动") }
            }
            return
        }

        let input = PolicyInput(
            builtin: snap.builtin,
            externals: snap.externals.map {
                ExternalDisplay(key: $0.key, isVirtual: $0.isVirtual, isAsleep: $0.isAsleep, rule: rule(for: $0.key))
            },
            manualOverride: model.manualOverride,
            autoDisablePaused: isFlapPaused,
            builtinMirrored: snap.builtinMirrored
        )
        let decision = Policy.decide(input)
        log.notice("评估（\(reason, privacy: .public)）内屏=\(String(describing: snap.builtin), privacy: .public) 外接=\(real.count, privacy: .public) → \(String(describing: decision), privacy: .public)")

        switch decision {
        case .leave:
            disableTimer.cancel()
        case .enable:
            disableTimer.cancel()
            if snap.builtin == .off { apply(on: true, reason: reason) }
        case .disable(let why):
            guard snap.builtin == .on else {
                disableTimer.cancel()
                return
            }
            if why == .manual {
                apply(on: false, reason: "手动")
                return
            }
            if fromTimer, pendingSignature == signature {
                apply(on: false, reason: "外接屏稳定 1.5 秒")
                return
            }
            if disableTimer.isPending, pendingSignature == signature { return } // 已经在倒计时
            disableLog.removeAll { Date().timeIntervalSince($0) > 10 }
            if disableLog.count >= 3 { // E13：10 秒内已经断开过 3 次
                startFlapPause()
                return
            }
            pendingSignature = signature
            disableTimer.schedule(after: 1.5) { [weak self] in self?.evaluate("倒计时结束", fromTimer: true) }
        }
    }

    private func rule(for key: String) -> Rule {
        settings.rule(for: key) ?? settings.defaultRule
    }

    private func apply(on: Bool, reason: String) {
        disableTimer.cancel()
        let ok = displays.setBuiltin(on)
        didApply = true
        log.notice("\(on ? "打开" : "关闭", privacy: .public)内屏（\(reason, privacy: .public)）→ \(ok ? "成功" : "失败", privacy: .public)")
        if !on, ok {
            disableLog.append(Date())
            if let id = displays.builtinID { onBuiltinDisabled?(id) }
        }
        // E12：过一会儿重新读取实际状态
        verifyTimer.schedule(after: 1.5) { [weak self] in self?.verify(expectOn: on) }
    }

    private func verify(expectOn: Bool) {
        let snap = displays.snapshot()
        guard snap.builtin == .on || snap.builtin == .off else { return }
        if (snap.builtin == .on) == expectOn {
            verifyAttempts = 0
            return
        }
        verifyAttempts += 1
        if verifyAttempts <= 1 {
            apply(on: expectOn, reason: "校验后重试")
            updatePhase(displays.snapshot())
            return
        }
        log.error("校验失败：内屏应为\(expectOn ? "开" : "关", privacy: .public)")
        verifyAttempts = 0
        failed = true
        model.problem = expectOn
            ? "内屏没能重新打开。可以按 ⌃⌥⌘D 再试，或者重新插拔一下外接屏。"
            : "内屏没能关闭。如果开着 BetterDisplay 之类的显示器工具，可能和它冲突了。"
        evaluate("校验失败")
    }

    private func startFlapPause() {
        log.notice("反复插拔，暂停自动关闭 1 分钟")
        flapUntil = Date().addingTimeInterval(60)
        disableTimer.cancel()
        flapTimer.schedule(after: 60) { [weak self] in
            self?.flapUntil = nil
            self?.disableLog.removeAll()
            self?.evaluate("暂停结束")
        }
    }

    // MARK: - 输出

    private func publish(_ snap: DisplaySnapshot) {
        model.builtin = snap.builtin
        model.canControl = displays.canControl
        model.externals = snap.externals.map { e in
            let saved = settings.rule(for: e.key)
            return ExternalRow(displayID: e.id, key: e.key, name: e.name, isVirtual: e.isVirtual, isAsleep: e.isAsleep,
                               rule: saved ?? settings.defaultRule, isNew: saved == nil && !e.isVirtual)
        }
        if !displays.hasAPI {
            model.problem = "这个系统版本里找不到关闭显示器的接口，Solune 现在只显示状态。"
        } else if displays.builtinID == nil {
            model.problem = "没有找到内建显示器。"
        }
    }

    private func updatePhase(_ snap: DisplaySnapshot) {
        let hasExternal = !snap.realExternals.isEmpty
        let phase: Phase
        if !displays.canControl {
            phase = .unsupported
        } else if failed {
            phase = .failed
        } else if isStabilizing {
            phase = .stabilizing
        } else if userPaused {
            phase = .paused(.user)
        } else if isFlapPaused {
            phase = .paused(.flapping)
        } else if disableTimer.isPending, let at = disableTimer.fireDate {
            phase = .countdown(until: at)
        } else if snap.builtin == .lidClosed || (snap.builtin == .off && hasExternal) {
            phase = .externalOnly
        } else {
            phase = hasExternal ? .both : .solo
        }
        model.phase = phase
        if phase != lastPhase || hasExternal != lastHasExternal {
            lastPhase = phase
            lastHasExternal = hasExternal
            onPhase?(phase, hasExternal)
        }
    }
}
