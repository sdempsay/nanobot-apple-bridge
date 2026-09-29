import Foundation
import Darwin
import EventKit
import AppleBridgeProtocol

// apple-bridge-helper — the signed, EventKit-owning piece of apple-bridge.
//
// Runs as the LaunchAgent's own program (no wrapper scripts, no `swift run`
// parent), so launchd makes it its own responsible process and the TCC grant
// attaches to this binary's identity, not to whatever terminal hosted it.
//
// Milestone 1: request full Reminders access, serve newline-delimited JSON on
// the Unix socket, answer `lists`. Everything else returns "not implemented".

let fileManager = FileManager.default
let socketPath = bridgeSocketPath
let baseDir = (socketPath as NSString).deletingLastPathComponent

func log(_ message: String) {
    FileHandle.standardError.write(Data("[apple-bridge-helper] \(message)\n".utf8))
}

func die(_ message: String, code: Int32) -> Never {
    log(message)
    exit(code)
}

/// Expected refusal. Exit 0 so KeepAlive (SuccessfulExit false) does not restart the job.
func stop(_ message: String) -> Never {
    log(message)
    exit(0)
}

// A client that closes mid-response must not kill the LaunchAgent.
_ = Darwin.signal(SIGPIPE, SIG_IGN)

// MARK: - Directory and socket hygiene

do {
    try fileManager.createDirectory(
        atPath: baseDir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
} catch {
    die("cannot prepare \(baseDir): \(error)", code: 1)
}

let endpoint: UnixSocketAddress
do {
    endpoint = try unixSocketAddress(path: socketPath)
} catch {
    stop("\(error)")
}

/// True if something is already accepting connections on our socket path.
func isLiveHelper() -> Bool {
    var addr = endpoint.addr
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }
    return withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            connect(fd, address, endpoint.length) == 0
        }
    }
}

if isLiveHelper() {
    stop("another helper is already listening on \(socketPath); exiting")
}
if fileManager.fileExists(atPath: socketPath) {
    try? fileManager.removeItem(atPath: socketPath)
    log("removed stale socket at \(socketPath)")
}

// MARK: - EventKit access

let store = EKEventStore()

// The completion handler may be delivered on the main queue, so nothing here may
// block the main thread. dispatchMain() keeps the process alive; the listener is
// started from the callback on a background queue.
store.requestFullAccessToReminders { granted, error in
    if let error {
        log("access request failed: \(error.localizedDescription)")
    }
    DispatchQueue.global(qos: .userInitiated).async {
        guard granted else {
            stop("Reminders access not granted; not restarting. "
                + "Allow it in System Settings, then kickstart the LaunchAgent.")
        }
        log("Reminders access granted")
        startServer(store: store)
    }
}

// MARK: - Socket server

/// Dispatch sources must stay retained while active — a local that goes out of
/// scope releases the source and events silently stop firing (connections then
/// sit in the kernel backlog: connect() succeeds, nothing is ever accepted).
var acceptSource: DispatchSourceRead?

func startServer(store: EKEventStore) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { die("socket() failed: \(String(cString: strerror(errno)))", code: 4) }

    var addr = endpoint.addr
    let bound = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            bind(fd, address, endpoint.length)
        }
    }
    guard bound == 0 else {
        let code = errno
        let message = "bind() failed: \(String(cString: strerror(code)))"
        if code == EADDRINUSE {
            stop(message)
        }
        die(message, code: 4)
    }
    // Directory 0700 is necessary but not sufficient: the socket file itself is 0600.
    chmod(socketPath, 0o600)
    guard listen(fd, 8) == 0 else {
        die("listen() failed: \(String(cString: strerror(errno)))", code: 5)
    }
    log("listening on \(socketPath)")

    let acceptQueue = DispatchQueue(label: "org.dempsay.apple-bridge.accept")
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
    source.setEventHandler {
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else { return }
        var noSigpipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                   socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global(qos: .userInitiated).async {
            handleConnection(fd: clientFD, store: store)
        }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    acceptSource = source
}

func handleConnection(fd: Int32, store: EKEventStore) {
    defer { close(fd) }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    readLoop: while true {
        let count = read(fd, &chunk, chunk.count)
        if count < 0 {
            if errno == EINTR { continue }
            break
        }
        if count == 0 { break }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            let response = handleRequest(line, store: store)
            guard var data = try? JSONEncoder().encode(response) else { continue }
            data.append(UInt8(ascii: "\n"))
            if writeAll(fd: fd, data: data) != 0 { break readLoop }
        }
    }
}

func handleRequest(_ data: Data, store: EKEventStore) -> BridgeResponse {
    guard let request = try? JSONDecoder().decode(BridgeRequest.self, from: data) else {
        return BridgeResponse(ok: false, error: "malformed request")
    }
    switch request.command {
    case .lists:
        return BridgeResponse(ok: true, result: jsonValue(from: reminderListsOnMain(store: store)))
    default:
        return BridgeResponse(
            ok: false,
            error: "command '\(request.command.rawValue)' is not implemented yet")
    }
}

/// Defensive marshaling: EventKit's synchronous accessors are called on the main
/// queue here. NOTE: this was NOT proven necessary — the original no-response bug
/// turned out to be a deallocated dispatch source (see acceptSource). Keeping the
/// main-queue hop because EKEventStore is safest used from a consistent queue and
/// it costs one dispatch. This runs on a connection queue, never on main, so the
/// semaphore wait cannot deadlock the main queue.
func reminderListsOnMain(store: EKEventStore) -> [ListInfo] {
    precondition(!Thread.isMainThread, "must not block the main queue")
    var lists: [ListInfo] = []
    let gate = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        lists = reminderLists(store: store)
        gate.signal()
    }
    gate.wait()
    return lists
}

func reminderLists(store: EKEventStore) -> [ListInfo] {
    let defaultId = store.defaultCalendarForNewReminders()?.calendarIdentifier
    return store.calendars(for: .reminder).map { calendar in
        ListInfo(
            id: calendar.calendarIdentifier,
            name: calendar.title,
            isDefault: calendar.calendarIdentifier == defaultId)
    }
}

dispatchMain()
