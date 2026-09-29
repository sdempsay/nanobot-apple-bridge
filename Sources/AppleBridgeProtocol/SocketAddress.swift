import Darwin
import Foundation

/// A `sockaddr_un` plus the length to pass to `bind` / `connect`.
///
/// One builder so the helper and the MCP client cannot disagree about truncation.
public struct UnixSocketAddress {
    public var addr: sockaddr_un
    public var length: socklen_t

    public init(addr: sockaddr_un, length: socklen_t) {
        self.addr = addr
        self.length = length
    }
}

public enum UnixSocketAddressError: Error, CustomStringConvertible {
    /// `sun_path` is a fixed buffer. The path must leave room for a trailing NUL.
    case pathTooLong(bytes: Int, maximum: Int)

    public var description: String {
        switch self {
        case .pathTooLong(let bytes, let maximum):
            return "socket path is \(bytes) bytes; sun_path holds \(maximum) plus a NUL"
        }
    }
}

/// Build an address for `path`. Fails instead of truncating.
///
/// The returned length includes the trailing NUL and is never larger than
/// `sockaddr_un`. Callers must not recompute it from the original string.
public func unixSocketAddress(path: String) throws -> UnixSocketAddress {
    let bytes = Array(path.utf8)
    var addr = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    let maximum = capacity - 1
    guard bytes.count <= maximum else {
        throw UnixSocketAddressError.pathTooLong(bytes: bytes.count, maximum: maximum)
    }
    addr.sun_family = sa_family_t(AF_UNIX)
    if !bytes.isEmpty {
        withUnsafeMutableBytes(of: &addr.sun_path) { target in
            guard let base = target.baseAddress else { return }
            bytes.withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress else { return }
                memcpy(base, sourceBase, source.count)
            }
        }
    }
    let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 2
    let length = offset + bytes.count + 1
    guard length <= MemoryLayout<sockaddr_un>.size else {
        throw UnixSocketAddressError.pathTooLong(bytes: bytes.count, maximum: maximum)
    }
    addr.sun_len = UInt8(length)
    return UnixSocketAddress(addr: addr, length: socklen_t(length))
}

/// Write `data` until it is all sent. Returns 0, or an errno. Does not raise `SIGPIPE`
/// by itself — the caller sets `SO_NOSIGPIPE` or ignores `SIGPIPE`.
public func writeAll(fd: Int32, data: Data) -> Int32 {
    if data.isEmpty {
        return 0
    }
    let total = data.count
    var offset = 0
    while offset < total {
        let wrote: Int = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.write(fd, base.advanced(by: offset), total - offset)
        }
        if wrote < 0 {
            if errno == EINTR {
                continue
            }
            return errno == 0 ? EINVAL : errno
        }
        if wrote == 0 {
            return EPIPE
        }
        offset += wrote
    }
    return 0
}
