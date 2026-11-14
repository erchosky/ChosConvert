import ChosConvertKit
import Foundation
import SwiftUI

/// Localized strings from the String Catalog (Resources/Localizable.xcstrings).
/// Views never hardcode user-facing text; they reference semantic keys.
enum L {
    static func s(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    static func f(_ key: String, _ args: any CVarArg...) -> String {
        String(format: s(key), locale: .current, arguments: args)
    }

    /// Localized text, or nil when the catalog has no entry for `key`.
    static func optional(_ key: String) -> String? {
        let v = s(key)
        return v == key ? nil : v
    }

    static func error(_ e: ChosError) -> String { optional("error.\(e.code)") ?? e.message }

    static func recovery(_ id: String) -> String { optional("recovery.\(id)") ?? id }

    static func step(_ id: String) -> String { optional("step.\(id)") ?? id }

    static func note(_ note: PlanNote) -> String? {
        guard let template = optional("note.\(note.code)") else { return nil }
        let args = note.args ?? []
        return args.isEmpty ? template : String(format: template, arguments: args.map { $0 as any CVarArg })
    }
}

extension Text {
    /// Localized `Text` from the package's String Catalog.
    init(l key: String) {
        self.init(LocalizedStringKey(key), bundle: .module)
    }
}

/// The UI target's resource bundle (String Catalog, assets).
enum UIResources {
    static var bundle: Bundle { .module }
}
