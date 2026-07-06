import XCTest
@testable import AgentLightCore

final class JSONNumberTests: XCTestCase {
    func testExactIntegerAcceptsMathematicallyIntegralLexemes() throws {
        let cases: [(String, Int)] = [
            ("0", 0),
            ("-0", 0),
            ("1.0", 1),
            ("10e-1", 1),
            ("1e2", 100),
            ("-1.20e1", -12),
            ("-0e999999999999999999999999999999999999999999", 0)
        ]

        for (lexeme, expected) in cases {
            XCTAssertEqual(try JSONNumber(lexeme: lexeme).exactInteger, expected)
        }
    }

    func testExactIntegerRejectsPrecisionLossAndOverflowWithoutExpandingExponent() throws {
        let rejected = [
            "1.0000000000000000000000000000000000000001",
            "9223372036854775808",
            "-9223372036854775809",
            "1e999999999999999999999999999999999999999999",
            "1e-999999999999999999999999999999999999999999"
        ]

        for lexeme in rejected {
            XCTAssertNil(try JSONNumber(lexeme: lexeme).exactInteger)
        }
    }
}
