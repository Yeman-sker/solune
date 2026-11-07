import AppKit
import QuartzCore

/// 三次贝塞尔缓动，参数和 CSS 的 cubic-bezier 一致。
struct Curve: Sendable {
    let x1, y1, x2, y2: Double

    static let linear = Curve(x1: 0, y1: 0, x2: 1, y2: 1)
    static let ease = Curve(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    static let easeOut = Curve(x1: 0, y1: 0, x2: 0.58, y2: 1)
    static let easeInOut = Curve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    /// 太阳落下：缓入缓出
    static let dial = Curve(x1: 0.45, y1: 0, x2: 0.25, y2: 1)
    static let spring = Curve(x1: 0.3, y1: 1.4, x2: 0.5, y2: 1)
    static let bounce = Curve(x1: 0.3, y1: 1.5, x2: 0.5, y2: 1)
    /// 恢复内屏：强回弹
    static let snappy = Curve(x1: 0.3, y1: 1.45, x2: 0.5, y2: 1)
    static let pop = Curve(x1: 0.3, y1: 1.7, x2: 0.5, y2: 1)

    func value(at t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        // x(s) 单调，二分求 s
        var lo = 0.0, hi = 1.0, s = t
        for _ in 0..<22 {
            s = (lo + hi) / 2
            if Self.bezier(s, x1, x2) < t { lo = s } else { hi = s }
        }
        return Self.bezier(s, y1, y2)
    }

    private static func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
    }
}

/// 菜单栏日月转盘的动画。
/// 只在有动画时才逐帧重画，静止时不占用 CPU。
@MainActor
final class IconAnimator {
    private struct Tween {
        let prop: Prop
        var from: Double?
        let to: Double
        let start: Double
        let duration: Double
        let curve: Curve
        let order: Int
    }

    private struct Loop {
        let low, high, period, start: Double
    }

    private(set) var state = IconState.initial
    var reduceMotion = false
    /// 有新动画时调用，让外面开始逐帧刷新
    var onNeedsFrames: (() -> Void)?
    var clock: () -> Double = { CACurrentMediaTime() }

    private var tweens: [Tween] = []
    private var loops: [Prop: Loop] = [:]
    private var order = 0
    private var angleTarget = 0.0
    private var lastHover = 0.0

    var isAnimating: Bool { !tweens.isEmpty || !loops.isEmpty }

    // MARK: - 状态 → 动画

    func show(_ phase: Phase, hasExternal: Bool) {
        cancelPending()
        rebaseAngle()
        let night = isNight

        switch phase {
        case .solo, .both:
            clearMarks()
            slideMini(phase == .both)
            animate(.moon, 1, 0.4)
            if night {
                sunrise()
            } else {
                animate(.stars, 0, 0.3)
                showRays()
                toSun(0.45)
                if phase == .both { shine(delay: 0.25) }
            }

        case .countdown(let until):
            // 稳定期倒计时：太阳匀速下沉，下沉的角度就是进度
            clearMarks()
            slideMini(true)
            showRays()
            animate(.moon, 1, 0.3)
            let remaining = max(0.3, until.timeIntervalSinceNow)
            turn(55, remaining, .linear)
            animate(.stars, 0.35, 0.5, delay: remaining * 0.73)

        case .externalOnly:
            // 内屏关闭：光芒收起，月亮升起，星星亮起
            clearMarks()
            slideMini(hasExternal)
            animate(.moon, 1, 0.4)
            hideRays()
            turn(180, night ? 0.5 : 0.8, night ? .easeInOut : .dial)
            animate(.stars, 0.35, 0.3)
            animate(.stars, 1, 0.5, delay: 0.52)

        case .stabilizing:
            // 唤醒后：转盘来回犹豫地晃，外接屏淡淡地呼吸
            clearMarks()
            let base: Double = night ? 180 : 0
            if hasExternal {
                animate(.miniX, 0, 0.3)
                loop(.mini, 0.2, 0.6, period: 1.4)
            } else {
                slideMini(false)
            }
            if night {
                animate(.moon, 0.45, 0.4)
                animate(.stars, 0.35, 0.4)
            }
            turn(base - 30, 0.75, .easeInOut)
            turn(base + 5, 0.75, .easeInOut, delay: 0.75)
            turn(base - 20, 0.75, .easeInOut, delay: 1.5)
            turn(base, 0.75, .easeInOut, delay: 2.25)

        case .paused:
            // 一朵云飘过来挡住半个太阳，右下角暂停标志
            showBadge(.pause)
            animate(.ring, 0, 0.4)
            animate(.disc, 1, 0.4)
            animate(.moon, 1, 0.3)
            animate(.cloud, 1, 0.5, .spring)
            animate(.stars, 0, 0.3)
            showRays()
            slideMini(hasExternal)
            toSun(0.5)

        case .failed, .unsupported:
            // 太阳变成日食的光环，右下角感叹号
            showBadge(.bang)
            animate(.cloud, 0, 0.35)
            animate(.disc, 0, 0.4)
            animate(.ring, 1, 0.4)
            hideRays()
            animate(.stars, 0, 0.3)
            slideMini(hasExternal)
            toSun(0.5)
        }
    }

    /// 悬停：太阳在上就闪一下光芒，月亮在上就让星星眨眼
    func hover() {
        let now = clock()
        guard now - lastHover > 0.8 else { return }
        lastHover = now
        if isNight, state[.stars] > 0.5 {
            animate(.starScale, 1.8, 0.24, .easeOut)
            animate(.starRot, 45, 0.24, .easeOut)
            animate(.starScale, 1, 0.36, .ease, delay: 0.24)
            animate(.starRot, 0, 0.36, .ease, delay: 0.24)
        } else if !isNight, state[.rays] > 0.5 {
            shine(delay: 0)
        }
    }

    /// 点击：轻轻拨一下转盘
    func wiggle() {
        guard !isAnimating(.angle) else { return }
        let a = angleTarget
        turn(a + 14, 0.11, .easeOut)
        turn(a - 6, 0.12, .easeInOut, delay: 0.11)
        turn(a, 0.18, .bounce, delay: 0.23)
    }

    // MARK: - 动作

    private var isNight: Bool {
        let a = state[.angle]
        return a > 90 && a < 270
    }

    /// 恢复内屏：星星瞬间消失，转盘快速转过去，太阳带着光芒弹出来
    private func sunrise() {
        set(.stars, 0)
        set(.rays, 0)
        set(.raysScale, 0.2)
        set(.raysRot, 0)
        animate(.rays, 1, 0.27, .ease)
        animate(.raysScale, 1.25, 0.27, .pop)
        animate(.raysScale, 1, 0.18, .ease, delay: 0.27)
        turn(360, 0.34, .snappy)
        turn(0, 0, .linear, delay: 0.36)
    }

    private func toSun(_ duration: Double) {
        let a = state[.angle]
        if abs(a) < 0.5, !isAnimating(.angle) {
            set(.angle, 0)
            angleTarget = 0
            return
        }
        // 还没过地平线就弹回去；已经是夜里就继续往前转到天亮
        let target = a < 90 ? 0 : 360.0
        turn(target, duration, .spring)
        if target != 0 { turn(0, 0, .linear, delay: duration + 0.02) }
    }

    private func shine(delay d: Double) {
        animate(.raysRot, 22, 0.315, .bounce, delay: d)
        animate(.raysScale, 1.18, 0.315, .bounce, delay: d)
        animate(.raysRot, 45, 0.385, .ease, delay: d + 0.315)
        animate(.raysScale, 1, 0.385, .ease, delay: d + 0.315)
        animate(.raysRot, 0, 0, .linear, delay: d + 0.71) // 8 道光芒转 45° 和原来一样，悄悄归零
    }

    private func showRays() {
        animate(.rays, 1, 0.25)
        animate(.raysScale, 1, 0.3, .bounce)
        animate(.raysRot, 0, 0.3, .bounce)
    }

    private func hideRays() {
        animate(.rays, 0, 0.25)
        animate(.raysScale, 0.4, 0.3, .bounce)
        animate(.raysRot, -30, 0.3, .bounce)
    }

    private func slideMini(_ on: Bool) {
        loops[.mini] = nil
        animate(.mini, on ? 1 : 0, 0.3, .ease)
        animate(.miniX, on ? 0 : 4, 0.45, .spring)
    }

    private func clearMarks() {
        animate(.cloud, 0, 0.35, .ease)
        animate(.badge, 0, 0.2)
        animate(.badgeScale, 0.4, 0.3)
        animate(.ring, 0, 0.4)
        animate(.disc, 1, 0.4)
    }

    private func showBadge(_ kind: BadgeKind) {
        state.badgeKind = kind
        animate(.badge, 1, 0.2)
        animate(.badgeScale, 1, 0.3, .pop)
    }

    private func turn(_ degrees: Double, _ duration: Double, _ curve: Curve, delay: Double = 0) {
        angleTarget = degrees
        animate(.angle, degrees, duration, curve, delay: delay)
    }

    /// 把角度挪回 [-90, 270) 区间，同时平移正在进行的转动，画面不变
    private func rebaseAngle() {
        let shift = 360 * ((state[.angle] + 90) / 360).rounded(.down)
        guard shift != 0 else { return }
        state[.angle] -= shift
        angleTarget -= shift
        tweens = tweens.map { t in
            guard t.prop == .angle else { return t }
            return Tween(prop: t.prop, from: t.from.map { $0 - shift }, to: t.to - shift, start: t.start,
                         duration: t.duration, curve: t.curve, order: t.order)
        }
    }

    // MARK: - 补间引擎

    private func animate(_ p: Prop, _ to: Double, _ duration: Double, _ curve: Curve = .easeInOut, delay: Double = 0) {
        order += 1
        let instant = reduceMotion
        tweens.append(Tween(prop: p, from: nil, to: to, start: clock() + (instant ? 0 : delay),
                            duration: instant ? 0 : duration, curve: curve, order: order))
        onNeedsFrames?()
    }

    private func set(_ p: Prop, _ value: Double) {
        tweens.removeAll { $0.prop == p }
        loops[p] = nil
        state[p] = value
        onNeedsFrames?()
    }

    private func loop(_ p: Prop, _ low: Double, _ high: Double, period: Double) {
        tweens.removeAll { $0.prop == p }
        if reduceMotion {
            state[p] = (low + high) / 2
        } else {
            loops[p] = Loop(low: low, high: high, period: period, start: clock())
        }
        onNeedsFrames?()
    }

    private func isAnimating(_ p: Prop) -> Bool { tweens.contains { $0.prop == p } }

    /// 取消还没开始的动画（正在进行的继续，被新动画接管时会平滑过渡）
    private func cancelPending() {
        let now = clock()
        tweens.removeAll { $0.start > now }
        loops.removeAll()
    }

    /// 推进到 now，返回画面是否有变化
    @discardableResult
    func step(at now: Double) -> Bool {
        // 同一个属性只保留最新开始的那段补间
        var latest: [Prop: Int] = [:]
        for (i, t) in tweens.enumerated() where t.start <= now {
            if let j = latest[t.prop] {
                let u = tweens[j]
                if (t.start, t.order) > (u.start, u.order) { latest[t.prop] = i }
            } else {
                latest[t.prop] = i
            }
        }

        var changed = false
        var keep: [Tween] = []
        for (i, var t) in tweens.enumerated() {
            if t.start > now {
                keep.append(t)
                continue
            }
            guard latest[t.prop] == i else { continue }
            let from = t.from ?? state[t.prop]
            t.from = from
            let progress = t.duration <= 0 ? 1 : min(1, (now - t.start) / t.duration)
            let value = from + (t.to - from) * t.curve.value(at: progress)
            if value != state[t.prop] {
                state[t.prop] = value
                changed = true
            }
            if progress < 1 { keep.append(t) }
        }
        tweens = keep

        for (p, l) in loops {
            let phase = (now - l.start) / l.period * 2 * .pi
            state[p] = l.low + (l.high - l.low) * (0.5 - 0.5 * cos(phase))
            changed = true
        }
        return changed
    }

    /// 直接跳到所有动画的终点（导出预览图用）
    func finish() {
        for (p, l) in loops { state[p] = (l.low + l.high) / 2 }
        loops.removeAll()
        var guardCount = 0
        while !tweens.isEmpty, guardCount < 50 {
            step(at: (tweens.map { $0.start + $0.duration }.max() ?? 0) + 1)
            guardCount += 1
        }
    }
}
