import Darwin
import AgentLightProtocol
import Foundation
import XCTest
@testable import AgentLightCore

final class RelayDeadlineTests: XCTestCase {
    func testImmediateSuccessClosesDescriptorExactlyOnce() {
        let system = RecordingDatagramSystem(sendSteps: [.result(.sent(5))])
        let sender = makeSender(system: system)

        XCTAssertTrue(sender.sendFailOpen(Data("event".utf8)))
        XCTAssertEqual(system.snapshot().openCount, 1)
        XCTAssertEqual(system.snapshot().sendCount, 1)
        XCTAssertEqual(system.snapshot().closeDescriptors, [41])
    }

    func testMissingSocketFailsOpenAndClosesDescriptorExactlyOnce() {
        let system = RecordingDatagramSystem(sendSteps: [.failure(ENOENT)])
        let sender = makeSender(system: system)

        XCTAssertFalse(sender.sendFailOpen(Data("event".utf8)))
        XCTAssertEqual(system.snapshot().waitDeadlines, [])
        XCTAssertEqual(system.snapshot().closeDescriptors, [41])
    }

    func testWouldBlockWaitsUntilWritableAndRetriesOnce() {
        let system = RecordingDatagramSystem(
            sendSteps: [.result(.wouldBlock), .result(.sent(5))],
            waitSteps: [.writable]
        )
        let sender = makeSender(system: system)

        XCTAssertTrue(sender.sendFailOpen(Data("event".utf8)))
        XCTAssertEqual(system.snapshot().sendCount, 2)
        XCTAssertEqual(system.snapshot().waitDeadlines.count, 1)
        XCTAssertEqual(system.snapshot().closeDescriptors, [41])
    }

    func testRepeatedInterruptedWaitsReuseTheSingleMonotonicDeadline() {
        let start = ContinuousClock().now
        let expectedDeadline = start.advanced(by: UnixDatagramSender.deliveryBudget)
        let system = RecordingDatagramSystem(
            sendSteps: [.result(.wouldBlock), .result(.sent(5))],
            waitSteps: [.interrupted, .interrupted, .writable]
        )
        let sender = makeSender(system: system, now: { start })

        XCTAssertTrue(sender.sendFailOpen(Data("event".utf8)))
        XCTAssertEqual(system.snapshot().waitDeadlines, [
            expectedDeadline,
            expectedDeadline,
            expectedDeadline
        ])
        XCTAssertEqual(system.snapshot().closeDescriptors, [41])
    }

    func testFullQueueExpiresAtTheInjectedOneHundredMillisecondBudget() {
        let start = ContinuousClock().now
        let system = RecordingDatagramSystem(
            sendSteps: [.result(.wouldBlock)],
            waitSteps: [.deadlineExpired]
        )
        let sender = makeSender(system: system, now: { start })

        XCTAssertFalse(sender.sendFailOpen(Data("event".utf8)))
        XCTAssertEqual(system.snapshot().waitDeadlines, [
            start.advanced(by: .milliseconds(100))
        ])
        XCTAssertEqual(system.snapshot().sendCount, 1)
        XCTAssertEqual(system.snapshot().closeDescriptors, [41])
    }

    func testFinalRetryWouldBlockFailsOpenWithoutWaitingAgain() {
        let system = RecordingDatagramSystem(
            sendSteps: [.result(.wouldBlock), .result(.wouldBlock)],
            waitSteps: [.writable]
        )
        let sender = makeSender(system: system)

        XCTAssertFalse(sender.sendFailOpen(Data("event".utf8)))
        XCTAssertEqual(system.snapshot().sendCount, 2)
        XCTAssertEqual(system.snapshot().waitDeadlines.count, 1)
        XCTAssertEqual(system.snapshot().closeDescriptors, [41])
    }

    func testInvalidPathAndOversizedPayloadAreRejectedBeforeTransport() {
        let invalidPathSystem = RecordingDatagramSystem(sendSteps: [])
        let invalidPathSender = UnixDatagramSender(
            path: "/tmp/invalid\0path",
            system: invalidPathSystem,
            now: { ContinuousClock().now }
        )
        let oversizedSystem = RecordingDatagramSystem(sendSteps: [])
        let oversizedSender = makeSender(system: oversizedSystem)

        XCTAssertFalse(invalidPathSender.sendFailOpen(Data("sensitive-input".utf8)))
        XCTAssertFalse(oversizedSender.sendFailOpen(
            Data(repeating: 0x41, count: RelayEnvelope.maximumEncodedBytes + 1)
        ))
        XCTAssertEqual(invalidPathSystem.snapshot().openCount, 0)
        XCTAssertEqual(oversizedSystem.snapshot().openCount, 0)
    }

    func testRelayProcessMissingSocketIsSilentAndFailOpen() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = packageRoot.appending(path: ".build/debug/AgentLightRelay")
        let fixedHome = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixedHome) }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--integration-id", AppIdentity.integrationIdentifier,
            "--source", "codex",
            "--event", "UserPromptSubmit"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = fixedHome.path
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        try inputPipe.fileHandleForWriting.write(contentsOf: Data(#"{"thread_id":"deadline-test"}"#.utf8))
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(outputPipe.fileHandleForReading.readDataToEndOfFile(), Data())
        XCTAssertEqual(errorPipe.fileHandleForReading.readDataToEndOfFile(), Data())
    }

    private func makeSender(
        system: RecordingDatagramSystem,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) -> UnixDatagramSender {
        UnixDatagramSender(path: "/tmp/agent-light-deadline.sock", system: system, now: now)
    }
}

private final class RecordingDatagramSystem: DatagramSendingSystem, @unchecked Sendable {
    enum SendStep {
        case result(DatagramSendResult)
        case failure(Int32)
    }

    enum WaitStep {
        case writable
        case deadlineExpired
        case interrupted
    }

    struct Snapshot {
        let openCount: Int
        let sendCount: Int
        let waitDeadlines: [ContinuousClock.Instant]
        let closeDescriptors: [Int32]
    }

    private let lock = NSLock()
    private var sendSteps: [SendStep]
    private var waitSteps: [WaitStep]
    private var openCount = 0
    private var sendCount = 0
    private var waitDeadlines: [ContinuousClock.Instant] = []
    private var closeDescriptors: [Int32] = []

    init(sendSteps: [SendStep], waitSteps: [WaitStep] = []) {
        self.sendSteps = sendSteps
        self.waitSteps = waitSteps
    }

    func openNonblockingDatagramSocket() throws -> Int32 {
        lock.withLock {
            openCount += 1
            return 41
        }
    }

    func send(_ data: Data, descriptor: Int32, address: sockaddr_un) throws -> DatagramSendResult {
        try lock.withLock {
            sendCount += 1
            guard !sendSteps.isEmpty else {
                throw UnixDatagramError.systemCall(name: "sendto", code: EIO)
            }
            switch sendSteps.removeFirst() {
            case let .result(result):
                return result
            case let .failure(code):
                throw UnixDatagramError.systemCall(name: "sendto", code: code)
            }
        }
    }

    func waitUntilWritable(
        _ descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) throws -> Bool {
        try lock.withLock {
            waitDeadlines.append(deadline)
            guard !waitSteps.isEmpty else {
                throw UnixDatagramError.systemCall(name: "poll", code: EIO)
            }
            switch waitSteps.removeFirst() {
            case .writable:
                return true
            case .deadlineExpired:
                return false
            case .interrupted:
                throw UnixDatagramError.systemCall(name: "poll", code: EINTR)
            }
        }
    }

    func close(_ descriptor: Int32) {
        lock.withLock {
            closeDescriptors.append(descriptor)
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                openCount: openCount,
                sendCount: sendCount,
                waitDeadlines: waitDeadlines,
                closeDescriptors: closeDescriptors
            )
        }
    }
}
