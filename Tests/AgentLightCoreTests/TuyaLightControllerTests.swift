import XCTest
@testable import AgentLightCore

final class TuyaLightControllerTests: XCTestCase {
    func testCurrentStateMatchRejectsDuplicateStatusAtBoundary() async throws {
        let credentials = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        let duplicateStatus = Self.status + [TuyaStatus(code: "switch_led", value: .bool(true))]
        let service = RecordingTuyaDeviceService(
            status: duplicateStatus,
            specification: Self.specification
        )
        let controller = TuyaLightController(
            credentials: ControllerCredentialStore(credentials: credentials),
            serviceFactory: { _ in service }
        )

        do {
            _ = try await controller.currentStateMatches(
                DesiredLightState(color: RGBColor(hex: 0x8B5CF6))
            )
            XCTFail("Expected duplicate status rejection")
        } catch let error as CapabilityError {
            XCTAssertEqual(error, .duplicateStatus("switch_led"))
        }
    }

    func testCapturesAppliesMatchesAndRestoresThroughResolvedCapabilities() async throws {
        let credentials = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        let credentialStore = ControllerCredentialStore(credentials: credentials)
        let service = RecordingTuyaDeviceService(status: Self.status, specification: Self.specification)
        let controller = TuyaLightController(
            credentials: credentialStore,
            serviceFactory: { received in
                XCTAssertEqual(received, credentials)
                return service
            }
        )

        let baseline = try await controller.captureBaseline()
        try await controller.apply(DesiredLightState(color: RGBColor(hex: 0x8B5CF6)))
        let matches = try await controller.currentStateMatches(
            DesiredLightState(color: RGBColor(hex: 0x8B5CF6))
        )
        try await controller.restore(baseline)

        XCTAssertEqual(baseline.values["switch_led"], .bool(false))
        XCTAssertTrue(matches)
        let commandBatches = await service.commandBatches
        XCTAssertEqual(commandBatches.count, 2)
        XCTAssertEqual(commandBatches[0].first, TuyaCommand(code: "switch_led", value: .bool(true)))
        XCTAssertEqual(commandBatches[1].last, TuyaCommand(code: "switch_led", value: .bool(false)))
    }

    private static let specification = TuyaSpecification(
        category: "dj",
        functions: [
            TuyaDataPointSpecification(code: "switch_led", type: "Boolean", values: "{}"),
            TuyaDataPointSpecification(code: "work_mode", type: "Enum", values: "{\"range\":[\"white\",\"colour\"]}"),
            TuyaDataPointSpecification(
                code: "colour_data_v2",
                type: "Json",
                values: "{\"h\":{\"min\":0,\"max\":360,\"scale\":0,\"step\":1},\"s\":{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1},\"v\":{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1}}"
            )
        ],
        status: []
    )

    private static let status: [TuyaStatus] = [
        TuyaStatus(code: "switch_led", value: .bool(false)),
        TuyaStatus(code: "work_mode", value: .string("colour")),
        TuyaStatus(code: "colour_data_v2", value: .string("{\"h\":0,\"s\":0,\"v\":500}"))
    ]
}

private final class ControllerCredentialStore: CredentialStoring, @unchecked Sendable {
    private let credentials: TuyaCredentials
    init(credentials: TuyaCredentials) { self.credentials = credentials }
    func save(_ credentials: TuyaCredentials) throws {}
    func load() throws -> TuyaCredentials? { credentials }
    func delete() throws {}
}

private actor RecordingTuyaDeviceService: TuyaDeviceServicing {
    private var currentStatus: [TuyaStatus]
    private let deviceSpecification: TuyaSpecification
    private(set) var commandBatches: [[TuyaCommand]] = []

    init(status: [TuyaStatus], specification: TuyaSpecification) {
        currentStatus = status
        deviceSpecification = specification
    }

    func status() async throws -> [TuyaStatus] { currentStatus }
    func specification() async throws -> TuyaSpecification { deviceSpecification }
    func send(commands: [TuyaCommand]) async throws {
        commandBatches.append(commands)
        for command in commands {
            let value: JSONValue
            if command.code == "colour_data_v2" {
                value = .string(try command.value.encodedString())
            } else {
                value = command.value
            }
            if let index = currentStatus.firstIndex(where: { $0.code == command.code }) {
                currentStatus[index] = TuyaStatus(code: command.code, value: value)
            } else {
                currentStatus.append(TuyaStatus(code: command.code, value: value))
            }
        }
    }
}
