import Foundation
import Testing
@testable import ChosConvertUI

@Suite struct LocalizationTests {
    func value(_ key: String, _ lang: String) -> String? {
        guard let path = UIResources.bundle.path(forResource: lang, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let v = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        return v == key ? nil : v
    }

    @Test func englishAndSpanishAreBundled() {
        #expect(value("home.drop.title", "en") == "Drop anything")
        #expect(value("home.drop.title", "es") == "Suelta lo que quieras")
        #expect(value("error.not_smaller", "es")?.contains("comprimido") == true)
    }

    @Test func formattingHelpers() {
        #expect(Fmt.resolution(3840, 2160).hasPrefix("4K"))
        #expect(Fmt.codec("hevc") == "HEVC")
        #expect(Fmt.percent(-0.957, signed: true).contains("96") || Fmt.percent(-0.957, signed: true).contains("95"))
    }
}
