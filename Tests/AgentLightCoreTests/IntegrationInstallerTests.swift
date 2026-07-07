import AgentLightProtocol
import Darwin
import Foundation
import XCTest
@testable import AgentLightCore

final class IntegrationInstallerTests: XCTestCase {
    func testFourArgumentPreviewInitializerRemainsSourceCompatible() {
        let preview = IntegrationPreview(source: .codex, path: "/CANARY", before: "{}", after: "{}")
        XCTAssertFalse(preview.hadOwnedEntries)
    }
    func testReceiptValidationRequiresExactlyOneEntryForEverySource() throws {
        let complete = AgentSource.allCases.map {
            IntegrationSourceReceipt(source: $0, ownership: .fresh)
        }
        XCTAssertNoThrow(try IntegrationInstallReceipt.validated(sources: complete))

        XCTAssertThrowsError(
            try IntegrationInstallReceipt.validated(sources: Array(complete.dropLast()))
        )
        XCTAssertThrowsError(
            try IntegrationInstallReceipt.validated(sources: complete + [complete[0]])
        )
    }

    func testInvalidReceiptOwnershipIsConservativelyMixed() {
        let receipt = IntegrationInstallReceipt(
            sources: [IntegrationSourceReceipt(source: .codex, ownership: .fresh)]
        )

        XCTAssertFalse(receipt.isValid)
        XCTAssertEqual(receipt.overallOwnership, .mixed)
    }

    func testLegacyCommittedCleanupErrorRemainsConstructible() {
        let error = IntegrationError.committedWithCleanupFailure(["CANARY_ARTIFACT"])

        guard case let .committedWithCleanupFailure(failures) = error else {
            return XCTFail("Expected legacy committed cleanup error")
        }
        XCTAssertEqual(failures, ["CANARY_ARTIFACT"])
    }

    func testLegacyInstallerConformerGetsConservativeReceiptWithoutSourceBreak() async throws {
        let installer = LegacyIntegrationInstaller()

        let receipt = try await installer.installWithReceipt()
        let installCount = await installer.installCount

        XCTAssertEqual(receipt.overallOwnership, .mixed)
        XCTAssertEqual(installCount, 1)
    }

    func testArtifactVerificationFindsOnlyKnownAgentLightArtifactsWithoutDeleting() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let installer = IntegrationInstaller(relayPath: "/tmp/CANARY_RELAY", paths: paths)
        let directory = paths.codex.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unrelated = directory.appending(path: ".unrelated.agent-light-rollback-CANARY")
        try Data("unrelated".utf8).write(to: unrelated)

        let cleanBeforeRetainedArtifact = try await installer.verifyArtifactCleanup()
        XCTAssertTrue(cleanBeforeRetainedArtifact)

        let retained = directory.appending(
            path: ".\(paths.codex.lastPathComponent).agent-light-rollback-CANARY"
        )
        try Data("retained".utf8).write(to: retained)

        let cleanAfterRetainedArtifact = try await installer.verifyArtifactCleanup()
        XCTAssertFalse(cleanAfterRetainedArtifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    func testArtifactVerificationPropagatesInspectionFailure() async {
        let root = temporaryRoot()
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let installer = IntegrationInstaller(
            relayPath: "/tmp/CANARY_RELAY",
            paths: paths,
            fileOperations: POSIXIntegrationFileOperations(),
            artifactInspector: FailingArtifactInspector()
        )

        await XCTAssertThrowsErrorAsync(try await installer.verifyArtifactCleanup())
    }

    func testInstallIsIdempotentAndPreservesUnrelatedHooks() throws {
        let original = Data(#"{"hooks":{"Custom":[{"hooks":[{"type":"command","command":"custom"}]}]}}"#.utf8)
        let editor = IntegrationConfigEditor(source: .codex, relayPath: "/tmp/AgentLightRelay")
        let once = try editor.install(into: original)
        let twice = try editor.install(into: once)
        XCTAssertEqual(once, twice)
        XCTAssertTrue(String(decoding: twice, as: UTF8.self).contains("custom"))
        XCTAssertEqual(
            try JSONValue.decode(editor.uninstall(from: twice)),
            try JSONValue.decode(original)
        )
    }

    func testJSONNumbersPreserveExactLargeIntegerFractionAndExponentLexemes() throws {
        let largeInteger = "12345678901234567890123456789012345678901234567890"
        let fraction = "-0.0012300"
        let exponent = "6.02214076e+23"
        let original = Data(
            "{\"large\":\(largeInteger),\"fraction\":\(fraction),\"exponent\":\(exponent)}".utf8
        )

        let encoded = try JSONValue.decode(original).encodedString()

        XCTAssertTrue(encoded.contains(largeInteger))
        XCTAssertTrue(encoded.contains(fraction))
        XCTAssertTrue(encoded.contains(exponent))
        XCTAssertEqual(try JSONValue.decode(Data(encoded.utf8)), try JSONValue.decode(original))
    }

    func testEquivalentJSONNumberLexemesCompareSemanticallyWithoutChangingEncoding() throws {
        let integer = try JSONValue.decode(Data("1".utf8))
        let fraction = try JSONValue.decode(Data("1.00".utf8))
        let exponent = try JSONValue.decode(Data("10e-1".utf8))

        XCTAssertEqual(integer, fraction)
        XCTAssertEqual(integer, exponent)
        XCTAssertEqual(try fraction.encodedString(), "1.00")
        XCTAssertEqual(try exponent.encodedString(), "10e-1")
    }

    func testSourceSpecificSchemasContainOnlyDocumentedEvents() throws {
        let expectedEvents: [AgentSource: Set<String>] = [
            .codex: ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"],
            .claudeCode: [
                "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop",
                "StopFailure", "SessionEnd", "Notification"
            ],
            .cursor: [
                "beforeSubmitPrompt", "preToolUse", "beforeShellExecution", "postToolUse",
                "afterShellExecution", "stop", "sessionEnd"
            ]
        ]

        for source in AgentSource.allCases {
            let editor = IntegrationConfigEditor(source: source, relayPath: "/tmp/Agent Light/AgentLightRelay")
            let installed = try JSONValue.decode(editor.install(into: Data()))
            let object = try XCTUnwrap(installed.objectValue)
            let hooks = try XCTUnwrap(object["hooks"]?.objectValue)
            XCTAssertEqual(Set(hooks.keys), expectedEvents[source])

            if source == .cursor {
                XCTAssertEqual(object["version"], .number(1))
                for value in hooks.values {
                    let handlers = try XCTUnwrap(value.arrayValue)
                    XCTAssertEqual(handlers.count, 1)
                    let handler = try XCTUnwrap(handlers.first?.objectValue)
                    XCTAssertEqual(Set(handler.keys), ["command"])
                }
            } else {
                XCTAssertNil(object["version"])
                for value in hooks.values {
                    let groups = try XCTUnwrap(value.arrayValue)
                    XCTAssertEqual(groups.count, 1)
                    let group = try XCTUnwrap(groups.first?.objectValue)
                    XCTAssertEqual(Set(group.keys), ["hooks"])
                    let handlers = try XCTUnwrap(group["hooks"]?.arrayValue)
                    let handler = try XCTUnwrap(handlers.first?.objectValue)
                    XCTAssertEqual(Set(handler.keys), ["command", "type"])
                }
            }
        }
    }

    func testOnlyExactAdjacentIntegrationArgumentsAreOwned() throws {
        let marker = AppIdentity.integrationIdentifier
        let original = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other --integration-id com.bbatchas.agentlight.hook.v1.extra"},{"type":"command","command":"other --label --integration-id com.bbatchas.agentlight.hook.v1"},{"type":"command","command":"other --integration-id 'com.bbatchas.agentlight.hook.v1'"}]}]}}"#.utf8)
        let editor = IntegrationConfigEditor(source: .codex, relayPath: "/tmp/AgentLightRelay")

        let uninstalled = try JSONValue.decode(editor.uninstall(from: original))
        let text = try uninstalled.encodedString()
        XCTAssertTrue(text.contains("\(marker).extra"))
        XCTAssertFalse(text.contains("other --label"))
        XCTAssertFalse(text.contains("other --integration-id '\(marker)'"))
    }

    func testRemovingOwnedHandlerPreservesSiblingFieldsAndUnrelatedGroups() throws {
        let marker = AppIdentity.integrationIdentifier
        let original = Data(#"{"other":{"nested":[true,null,1.25]},"hooks":{"Stop":[{"matcher":"custom","hooks":[{"type":"command","command":"custom"},{"type":"command","command":"relay --integration-id \#(marker) --source codex --event Stop"}]},{"matcher":"other","hooks":[{"type":"command","command":"another"}]}]}}"#.utf8)
        let expected = Data(#"{"other":{"nested":[true,null,1.25]},"hooks":{"Stop":[{"matcher":"custom","hooks":[{"type":"command","command":"custom"}]},{"matcher":"other","hooks":[{"type":"command","command":"another"}]}]}}"#.utf8)
        let editor = IntegrationConfigEditor(source: .codex, relayPath: "/tmp/AgentLightRelay")

        XCTAssertEqual(
            try JSONValue.decode(editor.uninstall(from: original)),
            try JSONValue.decode(expected)
        )
    }

    func testRemovingLastOwnedHandlerPreservesGroupWithUnrelatedFields() throws {
        let marker = AppIdentity.integrationIdentifier
        let original = Data(#"{"hooks":{"Stop":[{"matcher":"custom","hooks":[{"type":"command","command":"relay --integration-id \#(marker) --source codex --event Stop"}]}]}}"#.utf8)
        let expected = Data(#"{"hooks":{"Stop":[{"matcher":"custom","hooks":[]}]}}"#.utf8)
        let editor = IntegrationConfigEditor(source: .codex, relayPath: "/tmp/AgentLightRelay")

        XCTAssertEqual(
            try JSONValue.decode(editor.uninstall(from: original)),
            try JSONValue.decode(expected)
        )
    }

    func testInstallerPreviewDoesNotWriteAndInstallRepairUninstallAreAtomicAndPrivate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let installer = IntegrationInstaller(relayPath: "/Applications/Agent Light.app/Contents/MacOS/AgentLightRelay", paths: paths)

        let previews = try await installer.preview()
        XCTAssertEqual(previews.map(\.source), AgentSource.allCases)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codex.path))
        XCTAssertTrue(previews.allSatisfy { $0.before.isEmpty && $0.after.contains(AppIdentity.integrationIdentifier) })
        XCTAssertTrue(previews.allSatisfy { !$0.hadOwnedEntries })

        try await installer.install()
        for url in paths.all.map(\.url) {
            var metadata = stat()
            XCTAssertEqual(lstat(url.path, &metadata), 0)
            XCTAssertEqual(metadata.st_mode & mode_t(0o777), mode_t(0o600))
            _ = try JSONValue.decode(Data(contentsOf: url))
        }

        let installed = try paths.all.map { try Data(contentsOf: $0.url) }
        try await installer.repair()
        XCTAssertEqual(try paths.all.map { try Data(contentsOf: $0.url) }, installed)

        try await installer.uninstall()
        for url in paths.all.map(\.url) {
            XCTAssertEqual(try JSONValue.decode(Data(contentsOf: url)), .object([:]))
        }
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testPreviewReportsFullyPreexistingOwnedEntriesUsingExactParser() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let installer = IntegrationInstaller(relayPath: "/tmp/CANARY_RELAY", paths: paths)
        try await installer.install()

        let previews = try await installer.preview()

        XCTAssertEqual(previews.map(\.hadOwnedEntries), [true, true, true])
    }

    func testPreviewReportsPartialPreexistingOwnedEntriesPerSource() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let installer = IntegrationInstaller(relayPath: "/tmp/CANARY_RELAY", paths: paths)
        try await installer.install()
        try FileManager.default.removeItem(at: paths.claudeCode)
        try FileManager.default.removeItem(at: paths.cursor)

        let previews = try await installer.preview()
        let ownership = Dictionary(uniqueKeysWithValues: previews.map { ($0.source, $0.hadOwnedEntries) })

        XCTAssertEqual(ownership[.codex], true)
        XCTAssertEqual(ownership[.claudeCode], false)
        XCTAssertEqual(ownership[.cursor], false)
    }

    func testInstallReceiptUsesCommitTimeSnapshotsWhenEntriesAppearAfterFreshPreview() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let installer = IntegrationInstaller(relayPath: "/tmp/CANARY_RELAY", paths: paths)
        let preview = try await installer.preview()
        XCTAssertTrue(preview.allSatisfy { !$0.hadOwnedEntries })

        try await installer.install()
        let receipt = try await installer.installWithReceipt()

        XCTAssertEqual(receipt.overallOwnership, .fullyPreexisting)
        XCTAssertEqual(receipt.sources.map(\.ownership), [.fullyPreexisting, .fullyPreexisting, .fullyPreexisting])
    }

    func testInstallReceiptDetectsPartialEventDriftFromCommitTimeSnapshot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        try FileManager.default.createDirectory(
            at: paths.codex.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let marker = AppIdentity.integrationIdentifier
        let partial = Data(
            #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"relay --integration-id \#(marker) --source codex --event Stop"}]}]}}"#.utf8
        )
        try partial.write(to: paths.codex)
        let installer = IntegrationInstaller(relayPath: "/tmp/CANARY_RELAY", paths: paths)

        let receipt = try await installer.installWithReceipt()
        let ownership = Dictionary(uniqueKeysWithValues: receipt.sources.map { ($0.source, $0.ownership) })

        XCTAssertEqual(ownership[.codex], .partial)
        XCTAssertEqual(ownership[.claudeCode], .fresh)
        XCTAssertEqual(ownership[.cursor], .fresh)
        XCTAssertEqual(receipt.overallOwnership, .mixed)
    }

    func testInvalidExistingJSONFailsWithoutChangingFileOrLeavingArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        try FileManager.default.createDirectory(at: paths.codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("not-json".utf8)
        try invalid.write(to: paths.codex)
        let installer = IntegrationInstaller(relayPath: "/tmp/AgentLightRelay", paths: paths)

        await XCTAssertThrowsErrorAsync(try await installer.install())
        XCTAssertEqual(try Data(contentsOf: paths.codex), invalid)
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testStagingFailureLeavesDestinationUnchangedAndCleansArtifacts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let original = Data(#"{"original":true}"#.utf8)
        try write(original, to: paths.codex, mode: 0o640)
        let operations = FaultInjectingFileOperations(failFirstStagedWriteAfterSuccess: true)
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        await XCTAssertThrowsErrorAsync(try await installer.install())

        XCTAssertEqual(try Data(contentsOf: paths.codex), original)
        XCTAssertEqual(try mode(at: paths.codex), mode_t(0o640))
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testConcurrentModificationBeforeRenameIsNotOverwritten() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        try write(Data(#"{"original":true}"#.utf8), to: paths.codex)
        let concurrent = Data(#"{"concurrent":true}"#.utf8)
        let operations = FaultInjectingFileOperations(
            mutation: .replaceFile(url: paths.codex, data: concurrent)
        )
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        do {
            try await installer.install()
            XCTFail("Expected concurrent modification to abort installation")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .destinationChanged(paths.codex.path))
        }

        XCTAssertEqual(try Data(contentsOf: paths.codex), concurrent)
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testFileCreatedAfterMissingSnapshotIsNotOverwritten() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let concurrent = Data(#"{"created-concurrently":true}"#.utf8)
        let operations = FaultInjectingFileOperations(
            mutation: .replaceFile(url: paths.codex, data: concurrent)
        )
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        await XCTAssertThrowsErrorAsync(try await installer.install())

        XCTAssertEqual(try Data(contentsOf: paths.codex), concurrent)
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testInPlaceModificationBeforeRenameIsNotOverwritten() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        try write(Data(#"{"original":true}"#.utf8), to: paths.codex)
        let concurrent = Data(#"{"modified-in-place":true}"#.utf8)
        let operations = FaultInjectingFileOperations(
            mutation: .modifyFileInPlace(url: paths.codex, data: concurrent)
        )
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        await XCTAssertThrowsErrorAsync(try await installer.install())

        XCTAssertEqual(try Data(contentsOf: paths.codex), concurrent)
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testReplacementAfterPreRenameCheckIsAtomicallyRejected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        try write(Data(#"{"original":true}"#.utf8), to: paths.codex)
        let concurrent = Data(#"{"last-moment-replacement":true}"#.utf8)
        let operations = FaultInjectingFileOperations(
            mutationBeforeRename: .replaceFile(url: paths.codex, data: concurrent)
        )
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        await XCTAssertThrowsErrorAsync(try await installer.install())

        XCTAssertEqual(try Data(contentsOf: paths.codex), concurrent)
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testCreationAfterMissingPreRenameCheckIsAtomicallyRejected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let concurrent = Data(#"{"last-moment-creation":true}"#.utf8)
        let operations = FaultInjectingFileOperations(
            mutationBeforeRename: .replaceFile(url: paths.codex, data: concurrent)
        )
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        await XCTAssertThrowsErrorAsync(try await installer.install())

        XCTAssertEqual(try Data(contentsOf: paths.codex), concurrent)
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testSymlinkSubstitutionBeforeRenameIsNotOverwritten() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        try write(Data(#"{"original":true}"#.utf8), to: paths.codex)
        let victim = root.appending(path: "victim.json")
        let victimData = Data(#"{"victim":true}"#.utf8)
        try victimData.write(to: victim)
        let operations = FaultInjectingFileOperations(
            mutation: .replaceWithSymlink(url: paths.codex, destination: victim)
        )
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        await XCTAssertThrowsErrorAsync(try await installer.install())

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: paths.codex.path), victim.path)
        XCTAssertEqual(try Data(contentsOf: victim), victimData)
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testSecondRenameFailureRollsBackBytesAndOriginalMode() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let codexOriginal = Data(#"{"codex":true}"#.utf8)
        let claudeOriginal = Data(#"{"claude":true}"#.utf8)
        try write(codexOriginal, to: paths.codex, mode: 0o640)
        try write(claudeOriginal, to: paths.claudeCode, mode: 0o600)
        let operations = FaultInjectingFileOperations(failRenameCall: 2)
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        await XCTAssertThrowsErrorAsync(try await installer.install())

        XCTAssertEqual(try Data(contentsOf: paths.codex), codexOriginal)
        XCTAssertEqual(try mode(at: paths.codex), mode_t(0o640))
        XCTAssertEqual(try Data(contentsOf: paths.claudeCode), claudeOriginal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cursor.path))
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testPostRenameVerificationFailureRollsBackDestination() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let original = Data(#"{"original":true}"#.utf8)
        try write(original, to: paths.codex, mode: 0o640)
        let operations = FaultInjectingFileOperations(failVerificationAt: paths.codex)
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        await XCTAssertThrowsErrorAsync(try await installer.install())

        XCTAssertEqual(try Data(contentsOf: paths.codex), original)
        XCTAssertEqual(try mode(at: paths.codex), mode_t(0o640))
        XCTAssertTrue(try temporaryArtifacts(in: root).isEmpty)
    }

    func testCleanupFailureReportsCommittedStateAndPreservesProtectedRollbackArtifact() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        try write(Data(#"{"original":true}"#.utf8), to: paths.codex)
        let operations = FaultInjectingFileOperations(failRollbackCleanup: true)
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        do {
            try await installer.install()
            XCTFail("Expected committed cleanup failure")
        } catch let error as IntegrationError {
            guard case let .committedWithReceiptCleanupFailure(receipt, failures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(receipt.overallOwnership, .fresh)
            XCTAssertFalse(failures.isEmpty)
        }

        XCTAssertTrue(String(decoding: try Data(contentsOf: paths.codex), as: UTF8.self).contains(AppIdentity.integrationIdentifier))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.claudeCode.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cursor.path))
        let artifacts = try temporaryArtifacts(in: root)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(try mode(at: try XCTUnwrap(artifacts.first)), mode_t(0o600))
    }

    func testRollbackRestorationFailureIsReportedAndPreservesBackup() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        try write(Data(#"{"original":true}"#.utf8), to: paths.codex, mode: 0o640)
        let operations = FaultInjectingFileOperations(
            failVerificationAt: paths.codex,
            failRollbackRename: true
        )
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        do {
            try await installer.install()
            XCTFail("Expected rollback restoration failure")
        } catch let error as IntegrationError {
            guard case let .rollbackFailed(failures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(failures.isEmpty)
        }

        let artifacts = try temporaryArtifacts(in: root)
        XCTAssertEqual(artifacts.count, 2)
        let rollbackArtifacts = artifacts.filter { $0.lastPathComponent.contains("rollback") }
        XCTAssertEqual(rollbackArtifacts.count, 1)
        XCTAssertEqual(try mode(at: try XCTUnwrap(rollbackArtifacts.first)), mode_t(0o600))
    }

    func testInternalSwapBackFailurePreservesDisplacedAndRollbackRecoveryMaterial() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let original = Data(#"{"original":true}"#.utf8)
        let concurrent = Data(#"{"concurrent":true}"#.utf8)
        try write(original, to: paths.codex)
        let atomicRenamer = FailingSecondExchangeRenamer()
        let base = POSIXIntegrationFileOperations(atomicRenamer: atomicRenamer)
        let operations = FaultInjectingFileOperations(
            base: base,
            mutationBeforeRename: .replaceFileWithMode(url: paths.codex, data: concurrent, mode: 0o644)
        )
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        do {
            try await installer.install()
            XCTFail("Expected internal exchange restoration failure")
        } catch let error as IntegrationError {
            guard case let .rollbackFailed(failures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(failures.contains { $0.contains("atomic exchange restoration") })
        }

        XCTAssertTrue(String(decoding: try Data(contentsOf: paths.codex), as: UTF8.self).contains(AppIdentity.integrationIdentifier))
        let artifacts = try temporaryArtifacts(in: root)
        XCTAssertGreaterThanOrEqual(artifacts.count, 2)
        let artifactData = try artifacts.map { try Data(contentsOf: $0) }
        XCTAssertTrue(artifactData.contains(original))
        XCTAssertTrue(artifactData.contains(concurrent))
        XCTAssertTrue(try artifacts.allSatisfy { try mode(at: $0) == mode_t(0o600) })
    }

    func testMissingDestinationRollbackDoesNotDeleteConcurrentReplacementAfterVerification() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IntegrationConfigurationPaths(homeDirectory: root)
        let concurrent = Data(#"{"concurrent-after-verification":true}"#.utf8)
        let operations = FaultInjectingFileOperations(
            mutationBeforeRemove: .replaceFile(url: paths.codex, data: concurrent),
            failRenameCall: 2
        )
        let installer = IntegrationInstaller(
            relayPath: "/tmp/AgentLightRelay",
            paths: paths,
            fileOperations: operations
        )

        await XCTAssertThrowsErrorAsync(try await installer.install())

        XCTAssertEqual(try Data(contentsOf: paths.codex), concurrent)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        guard chmod(url.path, mode) == 0 else { throw POSIXError(.EIO) }
    }

    private func mode(at url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.ENOENT) }
        return metadata.st_mode & mode_t(0o777)
    }

    private func temporaryArtifacts(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent.contains("agent-light")
        }
    }
}

private final class FaultInjectingFileOperations: IntegrationFileOperating, @unchecked Sendable {
    enum Mutation: Sendable {
        case replaceFile(url: URL, data: Data)
        case replaceFileWithMode(url: URL, data: Data, mode: mode_t)
        case modifyFileInPlace(url: URL, data: Data)
        case replaceWithSymlink(url: URL, destination: URL)

        var target: URL {
            switch self {
            case let .replaceFile(url, _),
                 let .replaceFileWithMode(url, _, _),
                 let .modifyFileInPlace(url, _),
                 let .replaceWithSymlink(url, _):
                url
            }
        }
    }

    private let base: any IntegrationFileOperating
    private let lock = NSLock()
    private let mutation: Mutation?
    private let mutationBeforeRename: Mutation?
    private let mutationBeforeRemove: Mutation?
    private let failFirstStagedWriteAfterSuccess: Bool
    private let failRenameCall: Int?
    private let failVerificationAt: URL?
    private let failRollbackCleanup: Bool
    private let failRollbackRename: Bool
    private var destinationSnapshots: [String: Int] = [:]
    private var stagedWriteFailed = false
    private var renameMutationApplied = false
    private var removeMutationApplied = false
    private var renameCount = 0

    init(
        base: any IntegrationFileOperating = POSIXIntegrationFileOperations(),
        mutation: Mutation? = nil,
        mutationBeforeRename: Mutation? = nil,
        mutationBeforeRemove: Mutation? = nil,
        failFirstStagedWriteAfterSuccess: Bool = false,
        failRenameCall: Int? = nil,
        failVerificationAt: URL? = nil,
        failRollbackCleanup: Bool = false,
        failRollbackRename: Bool = false
    ) {
        self.base = base
        self.mutation = mutation
        self.mutationBeforeRename = mutationBeforeRename
        self.mutationBeforeRemove = mutationBeforeRemove
        self.failFirstStagedWriteAfterSuccess = failFirstStagedWriteAfterSuccess
        self.failRenameCall = failRenameCall
        self.failVerificationAt = failVerificationAt
        self.failRollbackCleanup = failRollbackCleanup
        self.failRollbackRename = failRollbackRename
    }

    func snapshot(at url: URL) throws -> IntegrationFileSnapshot {
        let count = withLock {
            destinationSnapshots[url.path, default: 0] += 1
            return destinationSnapshots[url.path, default: 0]
        }
        if count == 2, let mutation, mutation.target == url {
            try applyMutation(mutation)
        }
        if count == 3, failVerificationAt == url {
            throw IntegrationError.verificationFailed("injected: \(url.path)")
        }
        return try base.snapshot(at: url)
    }

    func createDirectory(at url: URL) throws {
        try base.createDirectory(at: url)
    }

    func writeProtected(_ data: Data, to url: URL) throws {
        try base.writeProtected(data, to: url)
        let shouldFail = withLock {
            guard
                failFirstStagedWriteAfterSuccess,
                !stagedWriteFailed,
                url.lastPathComponent.contains("staged")
            else {
                return false
            }
            stagedWriteFailed = true
            return true
        }
        if shouldFail {
            throw IntegrationError.fileOperation("injected staging failure")
        }
    }

    func replace(
        from source: URL,
        to destination: URL,
        expecting snapshot: IntegrationFileSnapshot
    ) throws {
        if failRollbackRename, source.lastPathComponent.contains("rollback") {
            throw IntegrationError.fileOperation("injected rollback rename failure")
        }
        let call = withLock {
            renameCount += 1
            return renameCount
        }
        let renameMutation = withLock { () -> Mutation? in
            guard !renameMutationApplied, mutationBeforeRename?.target == destination else { return nil }
            renameMutationApplied = true
            return mutationBeforeRename
        }
        if let renameMutation {
            try applyMutation(renameMutation)
        }
        if call == failRenameCall {
            throw IntegrationError.fileOperation("injected rename failure")
        }
        try base.replace(from: source, to: destination, expecting: snapshot)
    }

    func remove(at url: URL) throws {
        if failRollbackCleanup, url.lastPathComponent.contains("rollback") {
            throw IntegrationError.fileOperation("injected cleanup failure")
        }
        try base.remove(at: url)
    }

    func remove(at url: URL, expecting snapshot: IntegrationFileSnapshot) throws {
        let removeMutation = withLock { () -> Mutation? in
            guard !removeMutationApplied, mutationBeforeRemove?.target == url else { return nil }
            removeMutationApplied = true
            return mutationBeforeRemove
        }
        if let removeMutation {
            try applyMutation(removeMutation)
        }
        try base.remove(at: url, expecting: snapshot)
    }

    func setMode(_ mode: mode_t, at url: URL) throws {
        try base.setMode(mode, at: url)
    }

    func syncDirectory(at url: URL) throws {
        try base.syncDirectory(at: url)
    }

    private func applyMutation(_ mutation: Mutation) throws {
        switch mutation {
        case let .replaceFile(url, data):
            try data.write(to: url, options: .atomic)
        case let .replaceFileWithMode(url, data, mode):
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, mode) == 0 else { throw POSIXError(.EIO) }
        case let .modifyFileInPlace(url, data):
            try data.write(to: url)
        case let .replaceWithSymlink(url, destination):
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor LegacyIntegrationInstaller: IntegrationInstalling {
    private(set) var installCount = 0

    func preview() async throws -> [IntegrationPreview] { [] }
    func install() async throws { installCount += 1 }
    func repair() async throws {}
    func uninstall() async throws {}
}

private struct FailingArtifactInspector: IntegrationArtifactInspecting {
    func names(in directory: URL) throws -> [String] {
        throw IntegrationError.fileOperation("CANARY_INSPECTION_FAILURE")
    }
}

private final class FailingSecondExchangeRenamer: IntegrationAtomicRenaming, @unchecked Sendable {
    private let base = POSIXIntegrationAtomicRenamer()
    private let lock = NSLock()
    private var exchangeCount = 0

    func createExclusively(from source: URL, to destination: URL) throws {
        try base.createExclusively(from: source, to: destination)
    }

    func exchange(_ first: URL, with second: URL) throws {
        let call = withLock {
            exchangeCount += 1
            return exchangeCount
        }
        if call == 2 {
            throw IntegrationError.fileOperation("injected internal swap-back failure")
        }
        try base.exchange(first, with: second)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
