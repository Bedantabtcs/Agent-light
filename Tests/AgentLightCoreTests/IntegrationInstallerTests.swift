import AgentLightProtocol
import Darwin
import Foundation
import XCTest
@testable import AgentLightCore

final class IntegrationInstallerTests: XCTestCase {
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
