#if os(macOS)
import Foundation
import Darwin

public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

/// A native Swift client for libsearpc's length-prefixed named-pipe protocol.
public actor DaemonRPC {
    private let socketPath: String
    public init(socketPath: String) { self.socketPath = socketPath }
    public static func encodeCall(_ name: String, arguments: [JSONValue]) throws -> Data {
        let call = try JSONEncoder().encode([.string(name)] + arguments)
        return try JSONEncoder().encode(JSONValue.object(["service": .string("seafile-rpcserver"), "request": .string(String(decoding: call, as: UTF8.self))]))
    }
    public func call(_ name: String, _ arguments: [JSONValue] = []) throws -> JSONValue {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure() }
        defer { Darwin.close(fd) }
        var noPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SeafileError.local("The sync data path is too long for a Unix socket.") }
        withUnsafeMutableBytes(of: &address.sun_path) { target in path.withUnsafeBytes { target.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw failure() }
        let body = try Self.encodeCall(name, arguments: arguments)
        var count = UInt32(body.count).littleEndian
        let header = withUnsafeBytes(of: &count) { Data($0) }
        try send(fd, header + body)
        let replyHeader = try receive(fd, count: 4)
        let size = replyHeader.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard size > 0, size <= 16 * 1024 * 1024 else { throw SeafileError.invalidResponse }
        let reply = try JSONDecoder().decode(JSONValue.self, from: receive(fd, count: Int(size)))
        guard let object = reply.object else { throw SeafileError.invalidResponse }
        if object["err_code"] != nil { throw SeafileError.local(object["err_msg"]?.string ?? "The sync engine rejected the request.") }
        return object["ret"] ?? .null
    }
    private func send(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw failure() }
                offset += result
            }
        }
    }
    private func receive(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let result = Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw failure() }
                offset += result
            }
        }
        return data
    }
    private func failure() -> SeafileError { .local("Sync connection failed: \(String(cString: strerror(errno)))") }
}
#endif
