import CoreGraphics
import Darwin
import Foundation

/// 看门狗（E10）：内屏被关掉后，用同一个可执行文件拉起一个很小的子进程守着主程序。
/// 主程序正常退出时会先自己恢复内屏、再结束看门狗；
/// 如果主程序崩溃或被强制结束，看门狗会立刻重新打开内屏，然后把 App 重新拉起来。
@MainActor
final class WatchdogLauncher {
    private var pid: pid_t = 0
    private let launchedAt = Int(Date().timeIntervalSince1970)

    func ensureRunning(builtinID: CGDirectDisplayID) {
        if pid > 0 {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 { return } // 还活着
            pid = 0
        }
        guard let exe = Bundle.main.executablePath else { return }

        var args = [exe, "--watchdog", String(getpid()), String(builtinID), String(launchedAt)]
        if Bundle.main.bundleURL.pathExtension == "app" { args.append(Bundle.main.bundlePath) }
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0)=\($1)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // 放进自己的进程组，主程序被结束时它不会跟着被带走；
        // 主程序为了退出前恢复内屏而忽略了 SIGTERM 等信号，子进程要恢复成默认处理
        var defaults = sigset_t(), emptyMask = sigset_t()
        sigemptyset(&defaults)
        sigemptyset(&emptyMask)
        for sig in [SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, sig) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &emptyMask)

        var child: pid_t = 0
        if posix_spawn(&child, exe, nil, &attr, argv, envp) == 0 {
            pid = child
            log.notice("看门狗已启动 pid=\(child, privacy: .public)")
        }
    }

    func stop() {
        guard pid > 0 else { return }
        // 看门狗没有需要收尾的事，直接结束（SIGKILL 不会被忽略，退出流程不会卡住）
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        pid = 0
    }
}

/// 看门狗进程本体：在 main.swift 一开始调用，不会创建任何界面。
enum WatchdogProcess {
    static func runIfRequested() {
        let a = ProcessInfo.processInfo.arguments
        guard a.count >= 5, a[1] == "--watchdog",
              let parent = pid_t(a[2]), let builtin = UInt32(a[3]), let launchedAt = Double(a[4])
        else { return }
        let bundlePath = a.count > 5 ? a[5] : nil
        for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig, SIG_DFL) }

        let queue = kqueue()
        var change = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        var event = kevent()
        if kevent(queue, &change, 1, nil, 0, nil) == 0 {
            _ = kevent(queue, nil, 0, &event, 1, nil) // 一直等到主程序退出
        }

        // 走到这里说明主程序是意外退出的（正常退出会先结束看门狗）
        _ = DisplayAPI.setEnabled(builtin, true)

        // 主程序至少稳定运行过 30 秒才重新拉起，避免启动即崩溃时无限循环
        if let bundlePath, Date().timeIntervalSince1970 - launchedAt > 30 {
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/open"), strdup(bundlePath), nil]
            var pid: pid_t = 0
            posix_spawn(&pid, "/usr/bin/open", nil, nil, argv, nil)
        }
        exit(0)
    }
}
