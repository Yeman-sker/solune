import AppKit

// 看门狗子进程：守着主程序，不创建任何界面
WatchdogProcess.runIfRequested()

let arguments = ProcessInfo.processInfo.arguments
if let i = arguments.firstIndex(of: "--render-icons"), i + 1 < arguments.count {
    IconSheet.render(to: arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
