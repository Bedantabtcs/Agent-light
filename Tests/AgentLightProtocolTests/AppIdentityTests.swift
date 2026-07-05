import XCTest
@testable import AgentLightProtocol

final class AppIdentityTests: XCTestCase {
    func testStableIdentifiers() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.bbatchas.agentlight")
        XCTAssertEqual(AppIdentity.integrationIdentifier, "com.bbatchas.agentlight.hook.v1")
        XCTAssertEqual(AppIdentity.keychainService, "com.bbatchas.agentlight.tuya")
        XCTAssertTrue(AppIdentity.socketPath.hasSuffix("/agent-light-v1.sock"))
    }
}
