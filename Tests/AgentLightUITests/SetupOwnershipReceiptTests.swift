import Darwin
import Foundation
import XCTest
import AgentLightCore
import AgentLightProtocol
@testable import AgentLightUI

final class SetupOwnershipReceiptTests: XCTestCase {
    func testVersionOneReceiptRoundTripsWithoutCredentialMaterial() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateDirectory(at: root)
        let url = root.appending(path: "setup-ownership-v1.json")
        let store = FileSetupOwnershipStore(url: url)
        let receipt = makeReceipt()

        try await store.save(receipt)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, receipt)
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in [
            "accessID", "accessSecret", "deviceID", "endpoint",
            "CANARY_ACCESS_ID", "CANARY_ACCESS_SECRET", "CANARY_DEVICE_ID",
            "openapi.tuyaus.com"
        ] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), "Leaked \(forbidden)")
        }
    }

    func testSaveCreatesMode0600AndAtomicallyReplacesEarlierReceipt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateDirectory(at: root)
        let url = root.appending(path: "setup-ownership-v1.json")
        let store = FileSetupOwnershipStore(url: url)
        var first = makeReceipt()
        first.obligations = [.credentialDelete]
        var second = makeReceipt()
        second.obligations = [.integrationUninstallRetry]

        try await store.save(first)
        try await store.save(second)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, second)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, [url.lastPathComponent])
    }

    func testLoadRejectsSymlinkUnsafeModeMalformedAndUnsupportedReceipts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateDirectory(at: root)
        let url = root.appending(path: "setup-ownership-v1.json")
        let target = root.appending(path: "target.json")
        try Data("{}".utf8).write(to: target)
        XCTAssertEqual(symlink(target.path, url.path), 0)
        let store = FileSetupOwnershipStore(url: url)

        await assertStoreError(.unsafeReceipt) { try await store.load() }
        XCTAssertEqual(unlink(url.path), 0)

        try JSONEncoder().encode(makeReceipt()).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        await assertStoreError(.unsafeReceipt) { try await store.load() }

        try Data("not-json CANARY_PRIVATE_BYTES".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        await assertStoreError(.malformedReceipt) { try await store.load() }

        let unsupported = Data(#"{"version":2,"integration":{"none":{}},"credential":{"none":{}},"login":{"none":{}},"obligations":[]}"#.utf8)
        try unsupported.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        await assertStoreError(.unsupportedVersion) { try await store.load() }
    }

    func testSaveAndDeleteNeverReplaceOrRemoveUnknownSymlink() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateDirectory(at: root)
        let url = root.appending(path: "setup-ownership-v1.json")
        let target = root.appending(path: "unrelated.txt")
        let original = Data("CANARY_UNRELATED_CONTENT".utf8)
        try original.write(to: target)
        XCTAssertEqual(symlink(target.path, url.path), 0)
        let store = FileSetupOwnershipStore(url: url)

        await assertStoreError(.unsafeReceipt) { try await store.save(makeReceipt()) }
        await assertStoreError(.unsafeReceipt) { try await store.delete() }

        XCTAssertEqual(try Data(contentsOf: target), original)
        var metadata = stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK)
    }

    func testLedgerPersistsEveryDurableMutationAndHydratesNewInstance() async throws {
        let store = MemorySetupOwnershipStore()
        let first = AppOwnershipLedger(store: store)
        try await first.hydrate()
        let integration = PersistentIntegrationOwnership.uninstallable(makeIntegrationReceipt())

        try await first.update(.integration(integration))
        try await first.update(.credentials(.created))
        try await first.update(.login(.owned))
        try await first.update(.insertObligation(.integrationArtifactCleanup))

        let relaunched = AppOwnershipLedger(store: store)
        try await relaunched.hydrate()
        let snapshot = await relaunched.snapshot()
        XCTAssertEqual(snapshot.integration, integration)
        XCTAssertEqual(snapshot.credentials, .created)
        XCTAssertEqual(snapshot.login, .owned)
        XCTAssertEqual(snapshot.obligations, [.integrationArtifactCleanup])
        XCTAssertFalse(snapshot.monitoringOwned)
    }

    func testSaveFailurePreservesLastDurableSnapshotAndFailsClosed() async throws {
        let durable = makeReceipt()
        let store = FailingSetupOwnershipStore(stored: durable)
        let ledger = AppOwnershipLedger(store: store)
        try await ledger.hydrate()
        await store.failSaves()

        do {
            try await ledger.update(.credentials(.created))
            XCTFail("Expected persistence failure")
        } catch let error as SetupOwnershipStoreError {
            XCTAssertEqual(error, .writeFailed)
            XCTAssertFalse(String(describing: error).contains("CANARY"))
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.integration, durable.integration)
        XCTAssertEqual(snapshot.credentials, durable.credential)
        XCTAssertTrue(snapshot.obligations.contains(.ownershipReceiptRepair))
        XCTAssertFalse(snapshot.ownershipReceiptResetEligible)
        let stored = await store.current()
        XCTAssertEqual(stored, durable)
    }

    func testCorruptReceiptFailsClosedWithoutUninstallAuthority() async {
        let store = FailingSetupOwnershipStore(loadError: .malformedReceipt)
        let ledger = AppOwnershipLedger(store: store)

        do {
            try await ledger.hydrate()
            XCTFail("Expected receipt corruption")
        } catch let error as SetupOwnershipStoreError {
            XCTAssertEqual(error, .malformedReceipt)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.integration, .none)
        XCTAssertEqual(snapshot.credentials, .none)
        XCTAssertEqual(snapshot.login, .none)
        XCTAssertEqual(snapshot.obligations, [.ownershipReceiptRepair])
        XCTAssertTrue(snapshot.ownershipReceiptResetEligible)
    }

    func testOnlyMalformedUnsupportedAndOversizedReceiptsAreResetEligible() async {
        let eligible: [SetupOwnershipStoreError] = [
            .malformedReceipt,
            .unsupportedVersion,
            .receiptTooLarge
        ]
        for error in eligible {
            let ledger = AppOwnershipLedger(store: FailingSetupOwnershipStore(loadError: error))
            do { try await ledger.hydrate() } catch {}
            let snapshot = await ledger.snapshot()
            XCTAssertTrue(snapshot.ownershipReceiptResetEligible, "\(error)")
        }

        let ineligible: [SetupOwnershipStoreError] = [
            .readFailed,
            .writeFailed,
            .unsafeReceipt
        ]
        for error in ineligible {
            let ledger = AppOwnershipLedger(store: FailingSetupOwnershipStore(loadError: error))
            do { try await ledger.hydrate() } catch {}
            let snapshot = await ledger.snapshot()
            XCTAssertFalse(snapshot.ownershipReceiptResetEligible, "\(error)")
        }
    }

    func testConcurrentDurableMutationsCannotLoseAnEarlierReceiptUpdate() async throws {
        let store = ReentrantSetupOwnershipStore()
        let ledger = AppOwnershipLedger(store: store)
        try await ledger.hydrate()
        await store.blockFirstSave()
        let first = Task { try await ledger.update(.credentials(.created)) }
        await store.waitForFirstSave()
        let second = Task { try await ledger.update(.login(.owned)) }
        for _ in 0..<100 { await Task.yield() }

        await store.releaseFirstSave()
        try await first.value
        try await second.value

        let relaunched = AppOwnershipLedger(store: store)
        try await relaunched.hydrate()
        let snapshot = await relaunched.snapshot()
        XCTAssertEqual(snapshot.credentials, .created)
        XCTAssertEqual(snapshot.login, .owned)
    }

    func testAutomaticSaveAndDeletePreserveMalformedOwnerOwnedReceiptBytes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateDirectory(at: root)
        let url = root.appending(path: "setup-ownership-v1.json")
        let corrupt = Data("malformed CANARY_UNKNOWN_RECEIPT".utf8)
        try corrupt.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = FileSetupOwnershipStore(url: url)

        await assertStoreError(.malformedReceipt) { try await store.save(makeReceipt()) }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        await assertStoreError(.malformedReceipt) { try await store.delete() }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testAutomaticSaveAndDeletePreserveUnsupportedOwnerOwnedReceiptBytes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateDirectory(at: root)
        let url = root.appending(path: "setup-ownership-v1.json")
        let unsupported = makeReceipt()
        let current = try JSONEncoder().encode(unsupported)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        object["version"] = SetupOwnershipReceipt.currentVersion + 1
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = FileSetupOwnershipStore(url: url)

        await assertStoreError(.unsupportedVersion) { try await store.save(makeReceipt()) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        await assertStoreError(.unsupportedVersion) { try await store.delete() }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testExplicitResetQuarantinesMalformedBytesAndLeavesNoOwnershipAuthority() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateDirectory(at: root)
        let url = root.appending(path: "setup-ownership-v1.json")
        let invalidURL = root.appending(path: "setup-ownership-v1.invalid")
        let corrupt = Data("malformed CANARY_QUARANTINED_RECEIPT".utf8)
        try corrupt.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = FileSetupOwnershipStore(url: url)

        try await store.resetInvalidReceipt()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: invalidURL), corrupt)
        let attributes = try FileManager.default.attributesOfItem(atPath: invalidURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let loaded = try await store.load()
        XCTAssertNil(loaded)
    }

    func testExplicitResetQuarantinesOversizedUnknownBytes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateDirectory(at: root)
        let url = root.appending(path: "setup-ownership-v1.json")
        let invalidURL = root.appending(path: "setup-ownership-v1.invalid")
        let oversized = Data(repeating: 0x58, count: 64 * 1024 + 1)
        try oversized.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = FileSetupOwnershipStore(url: url)

        try await store.resetInvalidReceipt()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: invalidURL), oversized)
    }

    func testStoreRejectsSymlinkedAndNonprivateParentDirectories() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try createPrivateDirectory(at: root)
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        try createPrivateDirectory(at: target)
        let linked = root.appending(path: "linked", directoryHint: .isDirectory)
        XCTAssertEqual(symlink(target.path, linked.path), 0)
        let linkedStore = FileSetupOwnershipStore(
            url: linked.appending(path: "setup-ownership-v1.json")
        )

        await assertStoreError(.unsafeReceipt) { try await linkedStore.load() }

        let publicDirectory = root.appending(path: "public", directoryHint: .isDirectory)
        try createPrivateDirectory(at: publicDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: publicDirectory.path
        )
        let publicStore = FileSetupOwnershipStore(
            url: publicDirectory.appending(path: "setup-ownership-v1.json")
        )
        await assertStoreError(.unsafeReceipt) { try await publicStore.save(makeReceipt()) }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: publicDirectory.appending(path: "setup-ownership-v1.json").path
        ))
    }

    private func makeReceipt() -> SetupOwnershipReceipt {
        SetupOwnershipReceipt(
            version: SetupOwnershipReceipt.currentVersion,
            integration: .uninstallable(makeIntegrationReceipt()),
            credential: .replacedWithBackup,
            login: .owned,
            obligations: [.integrationArtifactCleanup]
        )
    }

    private func makeIntegrationReceipt() -> IntegrationInstallReceipt {
        IntegrationInstallReceipt(
            sources: AgentSource.allCases.map { source in
                IntegrationSourceReceipt(
                    source: source,
                    ownership: .fresh,
                    marker: AppIdentity.integrationIdentifier,
                    installedContentFingerprint: String(repeating: String(source.rawValue.first!), count: 64)
                )
            }
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "agent-light-ownership-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func assertStoreError(
        _ expected: SetupOwnershipStoreError,
        operation: () async throws -> some Any
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as SetupOwnershipStoreError {
            XCTAssertEqual(error, expected)
            XCTAssertFalse(String(describing: error).contains("CANARY_PRIVATE_BYTES"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor FailingSetupOwnershipStore: SetupOwnershipStoring {
    private var stored: SetupOwnershipReceipt?
    private let loadError: SetupOwnershipStoreError?
    private var saveError: SetupOwnershipStoreError?

    init(stored: SetupOwnershipReceipt? = nil, loadError: SetupOwnershipStoreError? = nil) {
        self.stored = stored
        self.loadError = loadError
    }

    func load() async throws -> SetupOwnershipReceipt? {
        if let loadError { throw loadError }
        return stored
    }

    func save(_ receipt: SetupOwnershipReceipt) async throws {
        if let saveError { throw saveError }
        stored = receipt
    }

    func delete() async throws {
        if let saveError { throw saveError }
        stored = nil
    }

    func failSaves() {
        saveError = .writeFailed
    }

    func current() -> SetupOwnershipReceipt? { stored }
}

private actor ReentrantSetupOwnershipStore: SetupOwnershipStoring {
    private var stored: SetupOwnershipReceipt?
    private var shouldBlockFirstSave = false
    private var firstSaveEntered = false
    private var firstSaveRelease: CheckedContinuation<Void, Never>?
    private var firstSaveWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async throws -> SetupOwnershipReceipt? { stored }

    func save(_ receipt: SetupOwnershipReceipt) async throws {
        if shouldBlockFirstSave {
            shouldBlockFirstSave = false
            firstSaveEntered = true
            let waiters = firstSaveWaiters
            firstSaveWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { firstSaveRelease = $0 }
        }
        stored = receipt
    }

    func delete() async throws { stored = nil }
    func blockFirstSave() { shouldBlockFirstSave = true }
    func waitForFirstSave() async {
        if firstSaveEntered { return }
        await withCheckedContinuation { firstSaveWaiters.append($0) }
    }
    func releaseFirstSave() {
        firstSaveRelease?.resume()
        firstSaveRelease = nil
    }
}
