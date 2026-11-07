import AppKit

/// 图标里所有会动的量。
enum Prop: Int, CaseIterable {
    /// 日月转盘的角度：0 = 太阳在上，180 = 月亮在上
    case angle
    case rays, raysScale, raysRot
    /// 太阳本体 / 日食光环
    case disc, ring
    case moon
    case stars, starScale, starRot
    /// 右侧小外接屏：透明度和水平偏移
    case mini, miniX
    case cloud
    case badge, badgeScale
}

enum BadgeKind: Sendable {
    case none, pause, bang
}

struct IconState: Sendable {
    var values = [Double](repeating: 0, count: Prop.allCases.count)
    var badgeKind: BadgeKind = .none

    subscript(p: Prop) -> Double {
        get { values[p.rawValue] }
        set { values[p.rawValue] = newValue }
    }

    static var initial: IconState {
        var s = IconState()
        s[.rays] = 1
        s[.raysScale] = 1
        s[.disc] = 1
        s[.moon] = 1
        s[.starScale] = 1
        s[.miniX] = 4
        s[.badgeScale] = 0.4
        return s
    }
}

/// 把 IconState 画成菜单栏模板图（只用透明度，系统负责深浅色和高亮着色）。
/// 坐标沿用原型 SVG 的 30 × 20 网格，y 轴向下。
enum IconRenderer {
    static let size = NSSize(width: 26, height: 17)
    private static let unit: CGFloat = 0.84
    private static let offset = CGPoint(x: 0.85, y: -0.1)

    static func image(_ s: IconState) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(s, in: ctx)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 在一个 y 向下、单位为点的 26 × 17 区域里画图标（黑色 + 透明度）。
    static func draw(_ s: IconState, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: unit, y: unit)
        ctx.translateBy(x: offset.x, y: offset.y)
        ctx.setFillColor(.black)
        ctx.setStrokeColor(.black)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 笔记本
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 1, y: 1.5, width: 20, height: 14.2), cornerWidth: 2.8, cornerHeight: 2.8, transform: nil))
        ctx.strokePath()
        ctx.addPath(CGPath(roundedRect: CGRect(x: -0.4, y: 16.8, width: 22.8, height: 1.9), cornerWidth: 0.95, cornerHeight: 0.95, transform: nil))
        ctx.fillPath()

        // 天空：地平线以下的部分藏起来
        ctx.saveGState()
        ctx.addPath(sky)
        ctx.clip()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawDial(s, ctx)
        let cloud = clamp(s[.cloud])
        if cloud > 0.001 {
            // 云挡住的地方把太阳挖掉，留出一圈空隙
            ctx.saveGState()
            ctx.setBlendMode(.destinationOut)
            ctx.setAlpha(cloud)
            ctx.translateBy(x: -4 * (1 - s[.cloud]), y: 0)
            ctx.setLineWidth(1.7)
            ctx.addPath(cloudPath)
            ctx.drawPath(using: .fillStroke)
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
        drawStars(s, ctx)
        ctx.restoreGState()

        // 地平线和沙丘
        ctx.setLineWidth(1.25)
        ctx.addPath(horizon)
        ctx.strokePath()
        ctx.saveGState()
        ctx.setAlpha(0.55)
        ctx.setLineWidth(0.9)
        ctx.addPath(dune)
        ctx.strokePath()
        ctx.restoreGState()

        // 云的轮廓
        if cloud > 0.001 {
            ctx.saveGState()
            ctx.setAlpha(cloud)
            ctx.translateBy(x: -4 * (1 - s[.cloud]), y: 0)
            ctx.setLineWidth(1.15)
            ctx.addPath(cloudPath)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 右侧的小外接屏
        let mini = clamp(s[.mini])
        if mini > 0.001 {
            ctx.saveGState()
            ctx.setAlpha(mini)
            ctx.translateBy(x: s[.miniX], y: 0)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 23.4, y: 5, width: 6.2, height: 7.6), cornerWidth: 1.3, cornerHeight: 1.3, transform: nil))
            ctx.addRect(CGRect(x: 26, y: 12.4, width: 1, height: 2.4))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 24.8, y: 14.6, width: 3.4, height: 1.2), cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }

        drawBadge(s, ctx)
    }

    private static func drawDial(_ s: IconState, _ ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: 11, y: 14)
        ctx.rotate(by: s[.angle] * .pi / 180)
        ctx.translateBy(x: -11, y: -14)

        // 太阳
        let disc = clamp(s[.disc])
        if disc > 0.001 {
            ctx.saveGState()
            ctx.setAlpha(disc)
            ctx.fillEllipse(in: CGRect(x: 8.7, y: 5.1, width: 4.6, height: 4.6))
            ctx.restoreGState()
        }
        let ring = clamp(s[.ring])
        if ring > 0.001 {
            ctx.saveGState()
            ctx.setAlpha(ring)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: 8.9, y: 5.3, width: 4.2, height: 4.2))
            ctx.restoreGState()
        }
        let rays = clamp(s[.rays])
        if rays > 0.001 {
            ctx.saveGState()
            ctx.setAlpha(rays)
            ctx.translateBy(x: 11, y: 7.4)
            ctx.rotate(by: s[.raysRot] * .pi / 180)
            ctx.scaleBy(x: s[.raysScale], y: s[.raysScale])
            ctx.translateBy(x: -11, y: -7.4)
            ctx.setLineWidth(1.05)
            for (a, b) in raySegments {
                ctx.move(to: a)
                ctx.addLine(to: b)
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 月亮：在转盘另一侧，转 180° 后出现在太阳的位置
        let moon = clamp(s[.moon])
        if moon > 0.001 {
            ctx.saveGState()
            ctx.setAlpha(moon)
            let outer = CGRect(x: 11 - 2.5, y: 20.6 - 2.5, width: 5, height: 5)
            ctx.addEllipse(in: outer)
            ctx.clip()
            ctx.addEllipse(in: outer)
            ctx.addEllipse(in: CGRect(x: 9.6 - 2.2, y: 21.5 - 2.2, width: 4.4, height: 4.4))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
    }

    private static func drawStars(_ s: IconState, _ ctx: CGContext) {
        let alpha = clamp(s[.stars])
        guard alpha > 0.001 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(alpha)
        for (center, r) in [(CGPoint(x: 5, y: 5.43), 1.33), (CGPoint(x: 16.9, y: 4.65), 1.05)] {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: s[.starRot] * .pi / 180)
            ctx.scaleBy(x: s[.starScale], y: s[.starScale])
            // 四角星：尖端 r，腰部 r × 0.29
            let w = r * 0.29
            ctx.move(to: CGPoint(x: 0, y: -r))
            ctx.addLine(to: CGPoint(x: w, y: -w))
            ctx.addLine(to: CGPoint(x: r, y: 0))
            ctx.addLine(to: CGPoint(x: w, y: w))
            ctx.addLine(to: CGPoint(x: 0, y: r))
            ctx.addLine(to: CGPoint(x: -w, y: w))
            ctx.addLine(to: CGPoint(x: -r, y: 0))
            ctx.addLine(to: CGPoint(x: -w, y: -w))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    private static func drawBadge(_ s: IconState, _ ctx: CGContext) {
        let alpha = clamp(s[.badge])
        guard alpha > 0.001, s.badgeKind != .none else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: 21, y: 16.4)
        ctx.scaleBy(x: s[.badgeScale], y: s[.badgeScale])
        ctx.translateBy(x: -21, y: -16.4)
        ctx.setAlpha(alpha)
        // 先挖出一圈空隙，再画实心圆，最后把符号镂空
        ctx.setBlendMode(.destinationOut)
        ctx.fillEllipse(in: CGRect(x: 21 - 3.9, y: 16.4 - 3.9, width: 7.8, height: 7.8))
        ctx.setBlendMode(.normal)
        ctx.fillEllipse(in: CGRect(x: 21 - 3.3, y: 16.4 - 3.3, width: 6.6, height: 6.6))
        ctx.setBlendMode(.destinationOut)
        switch s.badgeKind {
        case .pause:
            ctx.addPath(CGPath(roundedRect: CGRect(x: 19.7, y: 14.9, width: 1, height: 3), cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 21.3, y: 14.9, width: 1, height: 3), cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
        case .bang:
            ctx.addPath(CGPath(roundedRect: CGRect(x: 20.5, y: 14.3, width: 1, height: 2.4), cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
            ctx.addEllipse(in: CGRect(x: 20.4, y: 17.3, width: 1.2, height: 1.2))
        case .none:
            break
        }
        ctx.fillPath()
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    // MARK: - 几何

    private static let raySegments: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 14.3, y: 7.4), CGPoint(x: 15.5, y: 7.4)),
        (CGPoint(x: 13.33, y: 5.07), CGPoint(x: 14.18, y: 4.22)),
        (CGPoint(x: 11, y: 4.1), CGPoint(x: 11, y: 2.9)),
        (CGPoint(x: 8.67, y: 5.07), CGPoint(x: 7.82, y: 4.22)),
        (CGPoint(x: 7.7, y: 7.4), CGPoint(x: 6.5, y: 7.4)),
        (CGPoint(x: 8.67, y: 9.73), CGPoint(x: 7.82, y: 10.58)),
        (CGPoint(x: 11, y: 10.7), CGPoint(x: 11, y: 11.9)),
        (CGPoint(x: 13.33, y: 9.73), CGPoint(x: 14.18, y: 10.58)),
    ]

    nonisolated(unsafe) private static let sky: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 1.8, y: 2.3))
        p.addLine(to: CGPoint(x: 20.2, y: 2.3))
        p.addLine(to: CGPoint(x: 20.2, y: 12.3))
        p.addQuadCurve(to: CGPoint(x: 11, y: 12.6), control: CGPoint(x: 15.6, y: 13.2))
        p.addQuadCurve(to: CGPoint(x: 1.8, y: 12.9), control: CGPoint(x: 6.2, y: 11.6))
        p.closeSubpath()
        return p
    }()

    nonisolated(unsafe) private static let horizon: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 1.8, y: 12.9))
        p.addQuadCurve(to: CGPoint(x: 11, y: 12.6), control: CGPoint(x: 6.2, y: 11.6))
        p.addQuadCurve(to: CGPoint(x: 20.2, y: 12.3), control: CGPoint(x: 15.6, y: 13.2))
        return p
    }()

    nonisolated(unsafe) private static let dune: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 4.5, y: 14.5))
        p.addQuadCurve(to: CGPoint(x: 12.5, y: 14.4), control: CGPoint(x: 8.5, y: 13.7))
        return p
    }()

    /// 原型里的云：M5.4 10.4 H10.6 A1.15 … A2.1 … A1.5 … Z（圆弧圆心已经换算好）
    nonisolated(unsafe) private static let cloudPath: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 5.4, y: 10.4))
        p.addLine(to: CGPoint(x: 10.6, y: 10.4))
        p.addArc(center: CGPoint(x: 10.6, y: 9.25), radius: 1.15, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
        p.addArc(center: CGPoint(x: 8.5, y: 7.9), radius: 2.1095, startAngle: 0.0949, endAngle: -3.0467, clockwise: true)
        p.addArc(center: CGPoint(x: 6.2951, y: 9.1963), radius: 1.5, startAngle: -1.5008, endAngle: 2.2105, clockwise: true)
        p.closeSubpath()
        return p
    }()
}
