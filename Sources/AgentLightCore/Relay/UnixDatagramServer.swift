import Darwin
import AgentLightProtocol
import Foundation

public actor UnixDatagramServer {
    public typealias Handler = @Sendable (Data) async -> Void

    private let path: String
    private let maximumHandlerTasks: Int
    private var descriptor: Int32?
    private var readTask: Task<Void, Never>?
    private var handlerTaskRegistry: HandlerTaskRegistry?
    private var socketIdentity: SocketIdentity?

    public init(path: String) {
        self.path = path
        maximumHandlerTasks = 64
    }

    init(path: String, maximumHandlerTasks: Int) {
        precondition(maximumHandlerTasks > 0)
        self.path = path
        self.maximumHandlerTasks = maximumHandlerTasks
    }

    deinit {
        readTask?.cancel()
        handlerTaskRegistry?.cancelAll()
        if let socketIdentity {
            removeSocketIfOwned(path: path, identity: socketIdentity)
        }
    }

    public func start(handler: @escaping Handler) throws {
        guard descriptor == nil else {
            throw UnixDatagramError.alreadyRunning
        }

        var address = try unixDatagramAddress(for: path)
        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketDescriptor >= 0 else {
            throw UnixDatagramError.systemCall(name: "socket", code: errno)
        }

        var boundIdentity: SocketIdentity?
        var didStart = false
        defer {
            if !didStart {
                Darwin.close(socketDescriptor)
                if let boundIdentity {
                    removeSocketIfOwned(path: path, identity: boundIdentity)
                }
            }
        }

        if Darwin.unlink(path) != 0, errno != ENOENT {
            throw UnixDatagramError.systemCall(name: "unlink", code: errno)
        }

        let addressLength = socklen_t(address.sun_len)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(socketDescriptor, socketAddress, addressLength)
            }
        }
        guard bindResult == 0 else {
            throw UnixDatagramError.systemCall(name: "bind", code: errno)
        }

        boundIdentity = try requiredSocketIdentity(at: path)
        guard Darwin.chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            throw UnixDatagramError.systemCall(name: "chmod", code: errno)
        }

        didStart = true
        descriptor = socketDescriptor
        socketIdentity = boundIdentity
        let taskRegistry = HandlerTaskRegistry(maximumTaskCount: maximumHandlerTasks)
        handlerTaskRegistry = taskRegistry
        let maximumDatagramBytes = RelayEnvelope.maximumEncodedBytes
        readTask = Task.detached(priority: .userInitiated) {
            await Self.readDatagrams(
                from: socketDescriptor,
                maximumDatagramBytes: maximumDatagramBytes,
                taskRegistry: taskRegistry,
                handler: handler
            )
        }
    }

    public func stop() async {
        if let readTask {
            readTask.cancel()
            await readTask.value
        }
        if let handlerTaskRegistry {
            await handlerTaskRegistry.cancelAndWait()
        }
        if let socketIdentity {
            removeSocketIfOwned(path: path, identity: socketIdentity)
        }
        descriptor = nil
        readTask = nil
        handlerTaskRegistry = nil
        socketIdentity = nil
    }

    func outstandingHandlerTaskCount() -> Int {
        handlerTaskRegistry?.taskCount ?? 0
    }

    private nonisolated static func readDatagrams(
        from descriptor: Int32,
        maximumDatagramBytes: Int,
        taskRegistry: HandlerTaskRegistry,
        handler: @escaping Handler
    ) async {
        defer {
            Darwin.close(descriptor)
        }

        var buffer = [UInt8](repeating: 0, count: maximumDatagramBytes)
        while !Task.isCancelled {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pollDescriptor, 1, 50)
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            guard pollResult > 0 else {
                continue
            }
            guard pollDescriptor.revents & Int16(POLLIN) != 0 else {
                return
            }

            switch receiveDatagram(from: descriptor, into: &buffer) {
            case let .data(data):
                guard !Task.isCancelled else { return }
                taskRegistry.submit(data: data, handler: handler)
            case .retry, .truncated:
                continue
            case .failed:
                return
            }
        }
    }
}

enum DatagramSendResult: Equatable, Sendable {
    case sent(Int)
    case wouldBlock
}

protocol DatagramSendingSystem: Sendable {
    func openNonblockingDatagramSocket() throws -> Int32
    func send(_ data: Data, descriptor: Int32, address: sockaddr_un) throws -> DatagramSendResult
    func waitUntilWritable(_ descriptor: Int32, deadline: ContinuousClock.Instant) throws -> Bool
    func close(_ descriptor: Int32)
}

public struct UnixDatagramSender: Sendable {
    public static let deliveryBudget: Duration = .milliseconds(100)

    private let path: String
    private let system: any DatagramSendingSystem
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(path: String) {
        self.path = path
        system = DarwinDatagramSendingSystem()
        now = { ContinuousClock().now }
    }

    init(
        path: String,
        system: any DatagramSendingSystem,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.path = path
        self.system = system
        self.now = now
    }

    public func sendFailOpen(_ data: Data) -> Bool {
        guard data.count <= RelayEnvelope.maximumEncodedBytes,
              let address = try? unixDatagramAddress(for: path) else {
            return false
        }

        let deadline = now().advanced(by: Self.deliveryBudget)
        let descriptor: Int32
        do {
            descriptor = try system.openNonblockingDatagramSocket()
        } catch {
            return false
        }
        defer {
            system.close(descriptor)
        }

        let firstResult: DatagramSendResult
        do {
            firstResult = try system.send(data, descriptor: descriptor, address: address)
        } catch {
            return false
        }
        switch firstResult {
        case let .sent(byteCount):
            return byteCount == data.count
        case .wouldBlock:
            break
        }

        while true {
            do {
                guard try system.waitUntilWritable(descriptor, deadline: deadline) else {
                    return false
                }
                break
            } catch let UnixDatagramError.systemCall(name, code)
                where name == "poll" && code == EINTR {
                continue
            } catch {
                return false
            }
        }

        do {
            switch try system.send(data, descriptor: descriptor, address: address) {
            case let .sent(byteCount):
                return byteCount == data.count
            case .wouldBlock:
                return false
            }
        } catch {
            return false
        }
    }
}

public enum UnixDatagramError: Error, Sendable {
    case alreadyRunning
    case invalidPath
    case pathTooLong
    case incompleteSend
    case systemCall(name: String, code: Int32)
}

private func unixDatagramAddress(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)

    guard !pathBytes.contains(0) else {
        throw UnixDatagramError.invalidPath
    }
    guard pathBytes.count < pathCapacity else {
        throw UnixDatagramError.pathTooLong
    }

    address.sun_family = sa_family_t(AF_UNIX)
    guard let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) else {
        throw UnixDatagramError.invalidPath
    }
    let addressLength = pathOffset + pathBytes.count + 1
    guard addressLength <= UInt8.max else {
        throw UnixDatagramError.pathTooLong
    }
    address.sun_len = UInt8(addressLength)

    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        destination.copyBytes(from: pathBytes)
    }
    return address
}

private struct SocketIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}

private enum DatagramReceiveResult {
    case data(Data)
    case retry
    case truncated
    case failed
}

private final class HandlerTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumTaskCount: Int
    private var acceptsTasks = true
    private var nextID: UInt64 = 0
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var taskTail: Task<Void, Never>?

    init(maximumTaskCount: Int) {
        self.maximumTaskCount = maximumTaskCount
    }

    func submit(data: Data, handler: @escaping UnixDatagramServer.Handler) {
        lock.withLock {
            guard acceptsTasks, tasks.count < maximumTaskCount else { return }

            let id = nextID
            nextID &+= 1
            let previousTask = taskTail
            let task = Task(priority: .userInitiated) { [weak self] in
                if let previousTask {
                    await previousTask.value
                }
                guard !Task.isCancelled else {
                    self?.removeTask(id: id)
                    return
                }
                await handler(data)
                self?.removeTask(id: id)
            }
            tasks[id] = task
            taskTail = task
        }
    }

    var taskCount: Int {
        lock.withLock { tasks.count }
    }

    func cancelAll() {
        let runningTasks = lock.withLock {
            acceptsTasks = false
            return Array(tasks.values)
        }
        for task in runningTasks {
            task.cancel()
        }
    }

    func cancelAndWait() async {
        let runningTasks = lock.withLock {
            acceptsTasks = false
            return Array(tasks.values)
        }
        for task in runningTasks {
            task.cancel()
        }
        for task in runningTasks {
            await task.value
        }
        lock.withLock {
            tasks.removeAll(keepingCapacity: false)
            taskTail = nil
        }
    }

    private func removeTask(id: UInt64) {
        lock.withLock {
            tasks[id] = nil
        }
    }
}

private struct DarwinDatagramSendingSystem: DatagramSendingSystem {
    func openNonblockingDatagramSocket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw UnixDatagramError.systemCall(name: "socket", code: errno)
        }

        let existingFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw UnixDatagramError.systemCall(name: "fcntl", code: code)
        }
        guard Darwin.fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw UnixDatagramError.systemCall(name: "fcntl", code: code)
        }
        return descriptor
    }

    func send(
        _ data: Data,
        descriptor: Int32,
        address: sockaddr_un
    ) throws -> DatagramSendResult {
        var address = address
        let addressLength = socklen_t(address.sun_len)
        return try data.withUnsafeBytes { bytes in
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(
                        descriptor,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        socketAddress,
                        addressLength
                    )
                }
            }
            if result >= 0 {
                return .sent(result)
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return .wouldBlock
            }
            throw UnixDatagramError.systemCall(name: "sendto", code: errno)
        }
    }

    func waitUntilWritable(
        _ descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) throws -> Bool {
        let clock = ContinuousClock()
        let current = clock.now
        guard current < deadline else { return false }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let result = Darwin.poll(
            &pollDescriptor,
            1,
            pollTimeoutMilliseconds(for: current.duration(to: deadline))
        )
        if result < 0 {
            throw UnixDatagramError.systemCall(name: "poll", code: errno)
        }
        guard result > 0, clock.now <= deadline else { return false }
        guard pollDescriptor.revents & Int16(POLLOUT) != 0 else { return false }
        return true
    }

    func close(_ descriptor: Int32) {
        Darwin.close(descriptor)
    }
}

private func pollTimeoutMilliseconds(for duration: Duration) -> Int32 {
    let components = duration.components
    let millisecondsPerSecond: Int64 = 1_000
    let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
    let secondsMilliseconds = components.seconds.multipliedReportingOverflow(
        by: millisecondsPerSecond
    )
    guard !secondsMilliseconds.overflow else { return Int32.max }

    let fractionalMilliseconds = components.attoseconds / attosecondsPerMillisecond
    let hasFraction = components.attoseconds % attosecondsPerMillisecond != 0
    let roundedFraction = fractionalMilliseconds + (hasFraction ? 1 : 0)
    let total = secondsMilliseconds.partialValue.addingReportingOverflow(roundedFraction)
    guard !total.overflow else { return Int32.max }
    return Int32(clamping: max(1, total.partialValue))
}

private func receiveDatagram(
    from descriptor: Int32,
    into buffer: inout [UInt8]
) -> DatagramReceiveResult {
    buffer.withUnsafeMutableBytes { bytes in
        var vector = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
        var message = msghdr()
        let receivedByteCount = withUnsafeMutablePointer(to: &vector) { vectorPointer in
            message.msg_iov = vectorPointer
            message.msg_iovlen = 1
            return Darwin.recvmsg(descriptor, &message, MSG_DONTWAIT)
        }

        if receivedByteCount < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return .retry
            }
            return .failed
        }
        guard message.msg_flags & MSG_TRUNC == 0 else {
            return .truncated
        }
        return .data(Data(bytes.prefix(receivedByteCount)))
    }
}

private func requiredSocketIdentity(at path: String) throws -> SocketIdentity {
    var fileStatus = stat()
    guard Darwin.lstat(path, &fileStatus) == 0 else {
        throw UnixDatagramError.systemCall(name: "lstat", code: errno)
    }
    return SocketIdentity(device: fileStatus.st_dev, inode: fileStatus.st_ino)
}

private func removeSocketIfOwned(path: String, identity: SocketIdentity) {
    var fileStatus = stat()
    guard Darwin.lstat(path, &fileStatus) == 0 else {
        return
    }
    let currentIdentity = SocketIdentity(device: fileStatus.st_dev, inode: fileStatus.st_ino)
    guard currentIdentity == identity, fileStatus.st_mode & S_IFMT == S_IFSOCK else {
        return
    }
    Darwin.unlink(path)
}
