import AppKit

/// `--demo`：不碰显示器，只在菜单栏里循环播放各个状态的动画。
@MainActor
final class IconDemo {
    private let status: StatusItemController
    private let timer = Delay()
    private var index = 0
    private let steps: [(@MainActor () -> Phase, Bool, Double)] = [
        ({ .solo }, false, 2.5),
        ({ .countdown(until: Date().addingTimeInterval(1.5)) }, true, 1.55),
        ({ .externalOnly }, true, 3.5),
        ({ .solo }, false, 2.5),
        ({ .both }, true, 3),
        ({ .externalOnly }, true, 2.5),
        ({ .stabilizing }, true, 3),
        ({ .externalOnly }, true, 2.5),
        ({ .paused(.flapping) }, true, 3),
        ({ .failed }, false, 3),
    ]

    init(status: StatusItemController) {
        self.status = status
    }

    func start() { next() }

    private func next() {
        let (phase, hasExternal, hold) = steps[index % steps.count]
        status.show(phase(), hasExternal: hasExternal)
        index += 1
        timer.schedule(after: hold) { [weak self] in self?.next() }
    }
}

/// `--render-icons <目录>`：把每个状态的最终画面导出成 PNG，方便检查。
@MainActor
enum IconSheet {
    static func render(to directory: String) {
        let cases: [(String, [(Phase, Bool)])] = [
            ("只有内屏", [(.solo, false)]),
            ("倒计时", [(.solo, false), (.countdown(until: Date().addingTimeInterval(1.5)), true)]),
            ("仅外接", [(.externalOnly, true)]),
            ("双屏", [(.both, true)]),
            ("唤醒稳定期", [(.externalOnly, true), (.stabilizing, true)]),
            ("暂停", [(.paused(.flapping), true)]),
            ("出错", [(.failed, false)]),
        ]
        let states: [(String, IconState)] = cases.map { name, sequence in
            let animator = IconAnimator()
            for (phase, ext) in sequence {
                animator.show(phase, hasExternal: ext)
                animator.finish()
            }
            return (name, animator.state)
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        write(sheet(states, scale: 8), to: "\(directory)/icons-8x.png")
        write(sheet(states, scale: 2), to: "\(directory)/icons-2x.png")
    }

    private static func sheet(_ states: [(String, IconState)], scale: CGFloat) -> NSBitmapImageRep {
        let iconW = IconRenderer.size.width * scale, iconH = IconRenderer.size.height * scale
        let pad = max(12, scale * 3), label: CGFloat = scale >= 4 ? 28 : 0
        let cellW = iconW + pad * 2, cellH = iconH + pad * 2 + label
        let width = Int(cellW * CGFloat(states.count)), height = Int(cellH * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = g
        let ctx = g.cgContext

        let rows: [(CGColor, CGColor, NSColor)] = [
            (CGColor(gray: 0.93, alpha: 1), CGColor(gray: 0.1, alpha: 1), .darkGray),
            (CGColor(gray: 0.13, alpha: 1), CGColor(gray: 1, alpha: 1), .lightGray),
        ]
        for (r, (bg, ink, text)) in rows.enumerated() {
            let rowTop = CGFloat(height) - cellH * CGFloat(r + 1)
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: rowTop, width: CGFloat(width), height: cellH))
            for (i, (name, state)) in states.enumerated() {
                let x = cellW * CGFloat(i) + pad
                ctx.saveGState()
                // 换成 y 向下、单位为点的坐标
                ctx.translateBy(x: x, y: rowTop + cellH - pad)
                ctx.scaleBy(x: scale, y: -scale)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                IconRenderer.draw(state, in: ctx)
                ctx.setBlendMode(.sourceIn)
                ctx.setFillColor(ink)
                ctx.fill(CGRect(origin: .zero, size: IconRenderer.size))
                ctx.endTransparencyLayer()
                ctx.restoreGState()
                if label > 0 {
                    (name as NSString).draw(at: CGPoint(x: x, y: rowTop + 8),
                                            withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: text])
                }
            }
        }
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to path: String) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
