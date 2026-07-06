import AgentLightCore
import XCTest

final class MonitoringRecoveryPublicAPITests: XCTestCase {
    func testExternalStoreCanCreateOpaqueRevisionAndConformToProtocol() async throws {
        let store: any MonitoringRecoveryStoring = ExternalMemoryRecoveryStore()
        let record = MonitoringRecoveryRecord(baseline: BulbBaseline(values: [:]))

        let revision = try await store.save(record)
        let loaded = try await store.load()
        let stored = try XCTUnwrap(loaded)

        XCTAssertEqual(stored.revision, revision)
        try await store.clear(expecting: stored)
        let cleared = try await store.load()
        XCTAssertNil(cleared)
    }
}

private actor ExternalMemoryRecoveryStore: MonitoringRecoveryStoring {
    private var stored: StoredMonitoringRecovery?

    func load() -> StoredMonitoringRecovery? {
        stored
    }

    func save(_ record: MonitoringRecoveryRecord) -> MonitoringRecoveryRevision {
        let revision = MonitoringRecoveryRevision()
        stored = StoredMonitoringRecovery(record: record, revision: revision)
        return revision
    }

    func clear(expecting expected: StoredMonitoringRecovery) throws {
        guard stored == expected else {
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        stored = nil
    }
}
