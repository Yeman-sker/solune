import SoluneCore
import SwiftUI

@MainActor
protocol PanelActions: AnyObject {
    func setRule(_ rule: Rule, for key: String)
    func setDefaultRule(_ rule: Rule)
    func setBuiltinManually(_ on: Bool)
    func setPaused(_ paused: Bool)
    func setLaunchAtLogin(_ on: Bool)
    func retry()
    func quit()
}

struct PanelView: View {
    let model: AppModel
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)
            problemBanner
            Divider()
            builtinRow
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            if !model.externals.isEmpty {
                Divider()
                externalList
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            Divider()
            settingsRows
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 300)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Solune").font(.headline)
                    if model.dryRun {
                        Tag(text: "演练模式", color: .orange)
                    }
                }
                Text(model.statusTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var problemBanner: some View {
        if model.phase == .failed || model.phase == .unsupported, let problem = model.problem {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(problem)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.phase == .failed {
                    Button("重试") { actions.retry() }
                        .controlSize(.small)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    // MARK: - 内屏

    private var builtinRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("内建显示器")
                Text(builtinDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.builtin == .on }, set: { actions.setBuiltinManually($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!canToggleBuiltin)
        }
    }

    private var builtinDetail: String {
        switch model.builtin {
        case .lidClosed: return "合盖中"
        case .missing: return "没有找到"
        case .on, .off:
            let base = model.builtin == .on ? "开着" : "已关闭"
            if model.manualOverride != nil { return "\(base) · 临时，插拔后回到规则" }
            if model.builtin == .on, !model.hasRealExternal { return "\(base) · 唯一的屏幕，不能关" }
            return base
        }
    }

    private var canToggleBuiltin: Bool {
        guard model.canControl, model.phase != .failed else { return false }
        switch model.builtin {
        case .off: return true
        case .on: return model.hasRealExternal
        case .lidClosed, .missing: return false
        }
    }

    // MARK: - 外接屏

    private var externalList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("外接显示器")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.externals) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: row.isVirtual ? "rectangle.on.rectangle" : "display")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text(row.name).lineLimit(1)
                        if row.isNew { Tag(text: "新", color: .accentColor) }
                        if row.isAsleep { Tag(text: "休眠", color: .secondary) }
                        Spacer(minLength: 0)
                    }
                    Group {
                        if row.isVirtual {
                            Text("虚拟显示器不会让内屏关闭")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: Binding(get: { row.rule }, set: { actions.setRule($0, for: row.key) })) {
                                ForEach(Rule.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                    .padding(.leading, 34)
                }
            }
        }
    }

    // MARK: - 设置

    private var settingsRows: some View {
        VStack(spacing: 8) {
            row("新显示器默认") {
                Picker("", selection: Binding(get: { model.defaultRule }, set: { actions.setDefaultRule($0) })) {
                    ForEach(Rule.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("登录时打开") {
                Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { actions.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if model.loginNeedsApproval {
                Text("需要在「系统设置 › 通用 › 登录项」里允许 Solune")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            row("暂停自动管理") {
                Toggle("", isOn: Binding(get: { model.userPaused }, set: { actions.setPaused($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(!model.canControl)
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
        .frame(minHeight: 22)
    }

    private var footer: some View {
        HStack {
            Text("⌃⌥⌘D 紧急恢复内屏")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("退出") { actions.quit() }
                .controlSize(.small)
        }
    }
}

private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}
