import Darwin
import Foundation

public actor UnixDatagramServer {
    public typealias Handler = @Sendable (Data) async -> Void

    private let path: String
    private let maximumDatagramBytes: Int
    private var descriptor: Int32?
    private var readTask: Task<Void, Never>?
    private var socketIdentity: SocketIdentity?

    public init(path: String) {
        self.path = path
        maximumDatagramBytes = 4_096
    }

    init(path: String, maximumDatagramBytes: Int) {
        self.path = path
        self.maximumDatagramBytes = maximumDatagramBytes
    }

    deinit {
        readTask?.cancel()
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
        let maximumDatagramBytes = self.maximumDatagramBytes
        readTask = Task.detached(priority: .userInitiated) {
            await Self.readDatagrams(
                from: socketDescriptor,
                maximumDatagramBytes: maximumDatagramBytes,
                handler: handler
            )
        }
    }

    public func stop() async {
        if let readTask {
            readTask.cancel()
            await readTask.value
        }
        if let socketIdentity {
            removeSocketIfOwned(path: path, identity: socketIdentity)
        }
        descriptor = nil
        readTask = nil
        socketIdentity = nil
    }

    private nonisolated static func readDatagrams(
        from descriptor: Int32,
        maximumDatagramBytes: Int,
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
                await handler(data)
            case .retry, .truncated:
                continue
            case .failed:
                return
            }
        }
    }
}

public enum UnixDatagramSender {
    public static func send(_ data: Data, to path: String) throws {
        var address = try unixDatagramAddress(for: path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw UnixDatagramError.systemCall(name: "socket", code: errno)
        }
        defer {
            Darwin.close(descriptor)
        }

        let addressLength = socklen_t(address.sun_len)
        let sentByteCount = try data.withUnsafeBytes { bytes in
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
            guard result >= 0 else {
                throw UnixDatagramError.systemCall(name: "sendto", code: errno)
            }
            return result
        }

        guard sentByteCount == data.count else {
            throw UnixDatagramError.incompleteSend
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
