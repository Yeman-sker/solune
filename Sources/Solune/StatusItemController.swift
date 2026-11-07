import AppKit
import QuartzCore
import SwiftUI

/// 菜单栏图标：负责逐帧刷新动画、悬停和点击，以及弹出面板。
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let animator = IconAnimator()
    private let model: AppModel
    private weak var actions: PanelActions?
    private var link: CADisplayLink?
    private var popover: NSPopover?
    private var reduceMotionObserver: NSObjectProtocol?

    init(model: AppModel, actions: PanelActions) {
        self.model = model
        self.actions = actions
        super.init()

        animator.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animator.onNeedsFrames = { [weak self] in self?.startFrames() }
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.animator.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }

        guard let button = item.button else { return }
        button.image = IconRenderer.image(animator.state)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Solune")
        button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                              owner: self, userInfo: nil))
    }

    func show(_ phase: Phase, hasExternal: Bool) {
        animator.show(phase, hasExternal: hasExternal)
        item.button?.setAccessibilityValue(model.statusTitle)
        item.button?.toolTip = "Solune · \(model.statusTitle)"
    }

    // MARK: - 逐帧刷新（只在有动画时运行）

    private func startFrames() {
        guard let button = item.button else { return }
        if link == nil {
            let l = button.displayLink(target: self, selector: #selector(frame(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    @objc private func frame(_ link: CADisplayLink) {
        if animator.step(at: CACurrentMediaTime()) {
            item.button?.image = IconRenderer.image(animator.state)
        }
        if !animator.isAnimating { link.isPaused = true }
    }

    // MARK: - 交互

    @objc func mouseEntered(with event: NSEvent) {
        animator.hover()
    }

    @objc func mouseExited(with event: NSEvent) {}

    @objc private func clicked(_ sender: Any?) {
        animator.wiggle()
        togglePopover()
    }

    func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button, let actions else { return }
        // 面板只在打开时创建，关掉就释放，平时不占内存
        let host = NSHostingController(rootView: PanelView(model: model, actions: actions))
        host.sizingOptions = .preferredContentSize
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = host
        p.delegate = self
        popover = p
        NSApp.activate()
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
        popover = nil
    }
}
