import Foundation
import Testing
@testable import ChosConvertKit

@Suite struct CoreBridgeTests {
    @Test func abiMatches() throws {
        try CoreBridge.checkCompatibility()
        let info: CoreInfo = try CoreBridge.call("core.info")
        #expect(info.apiVersion == 1)
        #expect(!info.webpVersion.isEmpty)
    }

    @Test func structuredErrorsCrossTheBridge() {
        do {
            let _: Detection = try CoreBridge.call("detect.path", ["path": "relative.png"])
            Issue.record("expected error")
        } catch {
            #expect(error.code == "invalid_request")
            #expect(error.category == "validation")
        }
    }
}
