import Darwin
import XCTest
import AppleBridgeProtocol

final class SocketAddressTests: XCTestCase {
    func testShortPathLengthStaysInsideTheStruct() throws {
        let path = "/tmp/apple-bridge-test.sock"
        let endpoint = try unixSocketAddress(path: path)
        let offset = try XCTUnwrap(MemoryLayout.offset(of: \sockaddr_un.sun_path))
        XCTAssertEqual(Int(endpoint.length), offset + path.utf8.count + 1)
        XCTAssertLessThanOrEqual(Int(endpoint.length), MemoryLayout<sockaddr_un>.size)
        XCTAssertEqual(Int(endpoint.addr.sun_len), Int(endpoint.length))
        XCTAssertEqual(endpoint.addr.sun_family, sa_family_t(AF_UNIX))
    }

    func testPathThatFillsSunPathBinds() throws {
        let directory = FileManager.default.temporaryDirectory.path
        let prefixCount = directory.utf8.count + 1
        let maximum = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        try XCTSkipIf(prefixCount >= maximum, "temporary directory is already too long")
        let path = directory + "/" + String(repeating: "s", count: maximum - prefixCount)
        XCTAssertEqual(path.utf8.count, maximum)
        let endpoint = try unixSocketAddress(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer {
            close(fd)
            unlink(path)
        }
        var addr = endpoint.addr
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(fd, raw, endpoint.length)
            }
        }
        XCTAssertEqual(bound, 0, String(cString: strerror(errno)))
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        var clientAddr = endpoint.addr
        let connected = withUnsafePointer(to: &clientAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(client, raw, endpoint.length)
            }
        }
        XCTAssertEqual(connected, 0, String(cString: strerror(errno)))
    }

    func testOverlongPathIsRejected() {
        let maximum = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        let path = String(repeating: "p", count: maximum + 1)
        XCTAssertThrowsError(try unixSocketAddress(path: path)) { error in
            guard case UnixSocketAddressError.pathTooLong(let bytes, let limit) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(bytes, maximum + 1)
            XCTAssertEqual(limit, maximum)
        }
    }

    func testWriteAllDeliversTheWholeBuffer() throws {
        let pair = try socketPair()
        defer {
            close(pair.0)
            close(pair.1)
        }
        let payload = Data("{\"ok\":true}\n".utf8)
        XCTAssertEqual(writeAll(fd: pair.0, data: payload), 0)
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(pair.1, &buffer, buffer.count)
        XCTAssertEqual(count, payload.count)
        XCTAssertEqual(Data(buffer.prefix(count)), payload)
    }

    func testWriteAllReportsEPIPEWhenThePeerIsGone() throws {
        let pair = try socketPair()
        defer { close(pair.0) }
        var noSigpipe: Int32 = 1
        setsockopt(pair.0, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                   socklen_t(MemoryLayout<Int32>.size))
        close(pair.1)
        let error = writeAll(fd: pair.0, data: Data("hi\n".utf8))
        XCTAssertEqual(error, EPIPE)
    }

    private func socketPair() throws -> (Int32, Int32) {
        var fds: (Int32, Int32) = (0, 0)
        let created = withUnsafeMutablePointer(to: &fds) { pair in
            pair.withMemoryRebound(to: Int32.self, capacity: 2) { raw in
                socketpair(AF_UNIX, SOCK_STREAM, 0, raw)
            }
        }
        try XCTSkipIf(created != 0, "socketpair failed")
        return fds
    }
}
