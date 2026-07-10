import XCTest
@testable import AgentLightCore

final class AgentStateTests: XCTestCase {
    func testApprovedPaletteIsStable() {
        XCTAssertEqual(AgentState.thinking.color, RGBColor(hex: 0x8B5CF6))
        XCTAssertEqual(AgentState.working.color, RGBColor(hex: 0x3B82F6))
        XCTAssertEqual(AgentState.needsYou.color, RGBColor(hex: 0xF59E0B))
        XCTAssertEqual(AgentState.completed.color, RGBColor(hex: 0x22C55E))
        XCTAssertEqual(AgentState.error.color, RGBColor(hex: 0xFF0000))
        XCTAssertEqual(AgentState.reading.color, RGBColor(hex: 0x00FFFF))
        XCTAssertEqual(AgentState.editing.color, RGBColor(hex: 0xFFFF00))
        XCTAssertEqual(AgentState.testing.color, RGBColor(hex: 0xEC4899))
        XCTAssertEqual(AgentState.cancelled.color, RGBColor(hex: 0xFFD2A6))
    }
}
