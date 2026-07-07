import XCTest
@testable import AgentLightCore

final class TuyaDataCenterTests: XCTestCase {
    func testOfficialDataCentersHaveExactAllowlistedNamesAndEndpoints() {
        XCTAssertEqual(TuyaDataCenter.allCases.map(\.displayName), [
            "China", "Western America", "Eastern America", "Central Europe",
            "Western Europe", "India", "Singapore"
        ])
        XCTAssertEqual(TuyaDataCenter.allCases.map { $0.endpoint.absoluteString }, [
            "https://openapi.tuyacn.com",
            "https://openapi.tuyaus.com",
            "https://openapi-ueaz.tuyaus.com",
            "https://openapi.tuyaeu.com",
            "https://openapi-weaz.tuyaeu.com",
            "https://openapi.tuyain.com",
            "https://openapi-sg.iotbing.com"
        ])
    }

    func testAllowsOnlyExactOfficialOriginsAtRootAndEffectiveHTTPSPort() throws {
        XCTAssertEqual(
            TuyaDataCenter(endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyain.com"))),
            .india
        )
        XCTAssertEqual(
            TuyaDataCenter(endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyain.com:443/"))),
            .india
        )

        let invalid = [
            "https://evil.example",
            "https://openapi.tuyain.com.evil.example",
            "https://user@openapi.tuyain.com",
            "https://openapi.tuyain.com:8443",
            "https://openapi.tuyain.com/path",
            "https://openapi.tuyain.com?query=private",
            "https://openapi.tuyain.com#fragment",
            "http://openapi.tuyain.com"
        ]
        for value in invalid {
            XCTAssertNil(TuyaDataCenter(endpoint: try XCTUnwrap(URL(string: value))), value)
        }
    }
}
