import Darwin
import Foundation

public actor UnixDatagramServer {
    public typealias Handler = @Sendable (Data) async -> Void

    private let path: String
    private var descriptor: Int32?
    private var readTask: Task<Void, Never>?

    public init(path: String) {
        self.path = path
    }

    deinit {
        readTask?.cancel()
        if let descriptor {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.unlink(path)
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

        var didBind = false
        defer {
            if !didBind {
                Darwin.close(socketDescriptor)
                Darwin.unlink(path)
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

        guard Darwin.chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            throw UnixDatagramError.systemCall(name: "chmod", code: errno)
        }

        didBind = true
        descriptor = socketDescriptor
        readTask = Task.detached(priority: .userInitiated) {
            await Self.readDatagrams(
                from: socketDescriptor,
                handler: handler
            )
        }
    }

    public func stop() {
        readTask?.cancel()
        if let descriptor {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        Darwin.unlink(path)
        descriptor = nil
        readTask = nil
    }

    private nonisolated static func readDatagrams(
        from descriptor: Int32,
        handler: @escaping Handler
    ) async {
        defer {
            Darwin.close(descriptor)
        }

        var buffer = [UInt8](repeating: 0, count: 4_096)
        while !Task.isCancelled {
            let receivedByteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
            }

            if receivedByteCount >= 0 {
                guard !Task.isCancelled else { return }
                await handler(Data(buffer.prefix(receivedByteCount)))
            } else if errno != EINTR {
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
