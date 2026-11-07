import AppKit
import ServiceManagement
import SoluneCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, PanelActions {
    private let model = AppModel()
    private let settings = Settings()
    private let watchdog = WatchdogLauncher()
    private var displays: DisplayController?
    private var reconciler: Reconciler?
    private var status: StatusItemController?
    private var demo: IconDemo?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 只允许一个实例
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            exit(0)
        }

        let args = ProcessInfo.processInfo.arguments
        model.dryRun = args.contains("--dry-run")
        let status = StatusItemController(model: model, actions: self)
        self.status = status
        refreshLoginItem()

        if args.contains("--demo") {
            let demo = IconDemo(status: status)
            self.demo = demo
            demo.start()
            return
        }

        let displays = DisplayController(dryRun: model.dryRun)
        let reconciler = Reconciler(displays: displays, settings: settings, model: model)
        self.displays = displays
        self.reconciler = reconciler
        reconciler.onPhase = { [weak self] phase, hasExternal in
            self?.status?.show(phase, hasExternal: hasExternal)
        }
        reconciler.onBuiltinDisabled = { [weak self] id in
            guard let self, !self.model.dryRun else { return }
            self.watchdog.ensureRunning(builtinID: id)
        }
        reconciler.start()

        HotKey.register { [weak self] in self?.reconciler?.emergencyRestore() }

        if args.contains("--register-login-item") { // 安装脚本用：注册为登录时打开
            setLaunchAtLogin(true)
            log.notice("登录项状态：\(String(describing: SMAppService.mainApp.status), privacy: .public)")
        }

        if args.contains("--open-panel") { // 调试用：启动后直接打开面板
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.status?.togglePopover()
            }
        }

        // 被 kill / 注销时也走正常退出流程，先恢复内屏
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        reconciler?.restoreForQuit()
        watchdog.stop()
    }

    // MARK: - PanelActions

    func setRule(_ rule: Rule, for key: String) { reconciler?.setRule(rule, for: key) }
    func setDefaultRule(_ rule: Rule) { reconciler?.setDefaultRule(rule) }
    func setBuiltinManually(_ on: Bool) { reconciler?.setBuiltinManually(on) }
    func setPaused(_ paused: Bool) { reconciler?.setPaused(paused) }
    func retry() { reconciler?.retry() }
    func quit() { NSApp.terminate(nil) }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("登录项设置失败：\(error.localizedDescription, privacy: .public)")
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        model.launchAtLogin = status == .enabled || status == .requiresApproval
        model.loginNeedsApproval = status == .requiresApproval
    }
}
