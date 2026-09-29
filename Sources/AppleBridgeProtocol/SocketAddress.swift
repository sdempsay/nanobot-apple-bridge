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

/// Why reading one response frame failed.
public enum FrameReadError: Error, CustomStringConvertible {
    /// The peer never finished the frame inside the request's time budget.
    /// `hop` names the side that went quiet.
    case timeout(hop: String, budgetSeconds: Int)
    /// The peer closed the connection mid-frame.
    case closed
    /// `read` or `poll` failed for another reason.
    case posix(Int32)

    public var description: String {
        switch self {
        case .timeout(let hop, let seconds):
            return "no complete response from the helper: \(hop) did not answer within \(seconds) seconds"
        case .closed:
            return "helper closed the connection mid-response"
        case .posix(let code):
            return "read from helper failed (\(String(cString: strerror(code))))"
        }
    }
}

/// Read exactly one `\n`-terminated frame, bounded by `deadline`.
///
/// Byte at a time on purpose: a chunked read would swallow bytes belonging to the
/// next response on a reused connection. The cost is that a socket `SO_RCVTIMEO`
/// bounds only a single `read`, so a peer that dribbles one byte every 29 seconds
/// could hold an exchange open forever. `poll` against `deadline.secondsLeft` before
/// each byte caps the *whole frame* at one budget, however the peer paces itself —
/// and the wait can never compound past it.
public func readFrame(fd: Int32, deadline: Deadline, hop: String) throws -> Data {
    var buffer = Data()
    var byte: UInt8 = 0
    while true {
        let left = deadline.secondsLeft
        if left <= 0 {
            throw FrameReadError.timeout(hop: hop, budgetSeconds: Int(deadline.budgetSeconds))
        }
        var waiter = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&waiter, 1, Int32((left * 1000).rounded(.up)))
        if ready == 0 {
            throw FrameReadError.timeout(hop: hop, budgetSeconds: Int(deadline.budgetSeconds))
        }
        if ready < 0 {
            if errno == EINTR { continue }
            throw FrameReadError.posix(errno)
        }
        let count = Darwin.read(fd, &byte, 1)
        if count < 0 {
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw FrameReadError.posix(errno)
        }
        if count == 0 {
            throw FrameReadError.closed
        }
        if byte == UInt8(ascii: "\n") {
            return buffer
        }
        buffer.append(byte)
    }
}
