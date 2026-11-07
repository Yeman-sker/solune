import Foundation
import Observation
import SoluneCore

enum PauseReason: Equatable {
    /// 反复插拔，自动暂停 1 分钟
    case flapping
    /// 用户手动暂停（或按了紧急快捷键）
    case user
}

/// 菜单栏图标和面板共同展示的状态。
enum Phase: Equatable {
    case solo
    case both
    /// 发现外接屏，等 1.5 秒稳定后关闭内屏
    case countdown(until: Date)
    case externalOnly
    /// 唤醒后 3 秒稳定期
    case stabilizing
    case paused(PauseReason)
    /// 执行后校验失败，停止自动管理
    case failed
    /// 私有接口不可用或没有内屏：只显示状态
    case unsupported
}

struct ExternalRow: Identifiable, Equatable {
    var id: String { "\(displayID)/\(key)" }
    let displayID: UInt32
    let key: String
    let name: String
    let isVirtual: Bool
    let isAsleep: Bool
    let rule: Rule
    /// 第一次见到、还没手动选过规则
    let isNew: Bool
}

@MainActor @Observable
final class AppModel {
    var phase: Phase = .solo
    var builtin: BuiltinState = .on
    var externals: [ExternalRow] = []
    var defaultRule: Rule = .externalOnly
    var manualOverride: Bool?
    var userPaused = false
    var canControl = true
    var problem: String?
    var launchAtLogin = false
    var loginNeedsApproval = false
    var dryRun = false

    var hasRealExternal: Bool { externals.contains { !$0.isVirtual && !$0.isAsleep } }

    var statusTitle: String {
        switch phase {
        case .solo: "只有内屏"
        case .both: "内屏和外接屏都开着"
        case .countdown: "发现外接屏，马上关闭内屏"
        case .externalOnly: builtin == .lidClosed ? "合盖中，外接屏在工作" : "内屏已关闭，只用外接屏"
        case .stabilizing: "刚唤醒，等外接屏稳定"
        case .paused(.flapping): "检测到反复插拔，暂停 1 分钟"
        case .paused(.user): "自动管理已暂停"
        case .failed: "操作没有生效，已停止自动管理"
        case .unsupported: "只显示状态"
        }
    }
}
