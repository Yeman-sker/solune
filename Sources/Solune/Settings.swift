import Foundation
import SoluneCore

/// 只存两样东西：每块显示器的规则，和新显示器的默认规则。
@MainActor
final class Settings {
    private let defaults = UserDefaults.standard

    var defaultRule: Rule {
        get { defaults.string(forKey: "defaultRule").flatMap(Rule.init(rawValue:)) ?? .externalOnly }
        set { defaults.set(newValue.rawValue, forKey: "defaultRule") }
    }

    func rule(for key: String) -> Rule? {
        rules[key].flatMap(Rule.init(rawValue:))
    }

    func setRule(_ rule: Rule, for key: String) {
        var all = rules
        all[key] = rule.rawValue
        defaults.set(all, forKey: "rules")
    }

    private var rules: [String: String] {
        defaults.dictionary(forKey: "rules") as? [String: String] ?? [:]
    }
}
