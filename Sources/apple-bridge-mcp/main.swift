import Foundation
import Darwin
import AppleBridgeProtocol

// A helper restart must not deliver SIGPIPE to this process.
_ = Darwin.signal(SIGPIPE, SIG_IGN)

// apple-bridge-mcp — the stdio MCP front-end agents connect to.
//
// This target never links EventKit and needs no TCC grant: its only job is to
// translate MCP tool calls into newline-delimited JSON requests against the
// helper's Unix socket. It is ad-hoc signed on every build (Apple Silicon will
// not run a fully unsigned binary), and nothing in TCC attaches to it.
//
// Transport: MCP stdio is line-delimited JSON-RPC 2.0. stdout carries protocol
// messages only; diagnostics go to stderr.

// MARK: - Errors

enum MCPError: Error, CustomStringConvertible {
    case posix(String, Int32)
    case helperClosed
    case notConnected

    var description: String {
        switch self {
        case .posix(let message, let code):
            return "\(message) (\(String(cString: strerror(code))))"
        case .helperClosed:
            return "helper closed the connection mid-response"
        case .notConnected:
            return "not connected to the helper"
        }
    }

    /// Connection loss. Safe to drop the fd and try the call once more.
    /// `lists` is idempotent; a later mutating command must not assume that.
    var reconnectable: Bool {
        switch self {
        case .helperClosed:
            return true
        case .posix(_, let code):
            return code == EPIPE || code == ECONNRESET || code == ENOTCONN
                || code == ECONNABORTED || code == EAGAIN || code == EWOULDBLOCK
                || code == ETIMEDOUT
        case .notConnected:
            return false
        }
    }
}

// MARK: - Helper socket client

final class HelperClient {
    private var fd: Int32 = -1
    /// A helper that accepts and never answers must not stall the stdio loop.
    private static let ioTimeoutSeconds: time_t = 30

    private func closeFd() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private func ensureConnected() throws {
        guard fd < 0 else { return }
        let candidate = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard candidate >= 0 else { throw MCPError.posix("socket() failed", errno) }
        var noSigpipe: Int32 = 1
        setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                   socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Self.ioTimeoutSeconds, tv_usec: 0)
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(candidate, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLength)
        setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutLength)

        let endpoint: UnixSocketAddress
        do {
            endpoint = try unixSocketAddress(path: bridgeSocketPath)
        } catch {
            Darwin.close(candidate)
            throw MCPError.posix("\(error)", ENAMETOOLONG)
        }
        var addr = endpoint.addr
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.connect(candidate, address, endpoint.length)
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(candidate)
            throw MCPError.posix("helper is not listening on \(bridgeSocketPath)", code)
        }
        fd = candidate
    }

    func send(_ request: BridgeRequest) throws -> BridgeResponse {
        try ensureConnected()
        do {
            return try exchange(request)
        } catch let error as MCPError where error.reconnectable {
            closeFd()
            try ensureConnected()
            return try exchange(request)
        }
    }

    private func exchange(_ request: BridgeRequest) throws -> BridgeResponse {
        var payload = try JSONEncoder().encode(request)
        payload.append(UInt8(ascii: "\n"))
        let writeError = writeAll(fd: fd, data: payload)
        if writeError != 0 {
            throw MCPError.posix("write to helper failed", writeError)
        }
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                throw MCPError.posix("read from helper failed", errno)
            }
            if count == 0 { throw MCPError.helperClosed }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        return try JSONDecoder().decode(BridgeResponse.self, from: buffer)
    }
}

// MARK: - JSON-RPC 2.0

enum RequestID: Codable, Equatable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

struct RPCRequest: Decodable {
    var jsonrpc: String
    var id: RequestID?
    var method: String
    var params: [String: JSONValue]?
}

struct RPCErrorObject: Encodable {
    var code: Int
    var message: String
}

struct RPCResponse: Encodable {
    var jsonrpc: String = "2.0"
    var id: RequestID?
    var result: JSONValue?
    var error: RPCErrorObject?
}

// MARK: - MCP surface

let serverName = "apple-bridge"
let serverVersion = "0.1.0"
let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

let toolDefinitions: JSONValue = .array([
    .object([
        "name": .string("lists"),
        "description": .string(
            "List the user's Reminders lists. Each entry has id (an EventKit "
            + "calendarIdentifier — use this to address a list), name, and isDefault."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]),
    ])
])

func initializeResult(clientVersion: String?) -> JSONValue {
    let negotiated = clientVersion.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil }
        ?? supportedProtocolVersions[0]
    return .object([
        "protocolVersion": .string(negotiated),
        "capabilities": .object(["tools": .object([:])]),
        "serverInfo": .object([
            "name": .string(serverName),
            "version": .string(serverVersion),
        ]),
    ])
}

func callTool(_ client: HelperClient, params: [String: JSONValue]?) -> JSONValue {
    var name = ""
    if case .string(let value)? = params?["name"] { name = value }
    guard name == "lists" else {
        return toolError("unknown tool '\(name)'")
    }
    do {
        let response = try client.send(BridgeRequest(command: .lists))
        guard response.ok else {
            return toolError(response.error ?? "helper returned an error")
        }
        let text: String
        if let result = response.result {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            text = String(decoding: try encoder.encode(result), as: UTF8.self)
        } else {
            text = "null"
        }
        return .object([
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(text),
            ])]),
            "isError": .bool(false),
        ])
    } catch let error as MCPError {
        return toolError("could not reach the helper: \(error). "
            + "Is apple-bridge-helper running under its LaunchAgent?")
    } catch {
        return toolError("helper call failed: \(error)")
    }
}

func toolError(_ message: String) -> JSONValue {
    .object([
        "content": .array([.object([
            "type": .string("text"),
            "text": .string(message),
        ])]),
        "isError": .bool(true),
    ])
}

// MARK: - stdio loop

func logE(_ message: String) {
    FileHandle.standardError.write(Data("[apple-bridge-mcp] \(message)\n".utf8))
}

func writeLine(_ string: String) {
    FileHandle.standardOutput.write(Data("\(string)\n".utf8))
}

func respond(_ response: RPCResponse) {
    guard let data = try? JSONEncoder().encode(response),
          let line = String(data: data, encoding: .utf8) else { return }
    writeLine(line)
}

let client = HelperClient()

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { continue }
    guard let data = trimmed.data(using: .utf8) else { continue }

    guard let request = try? JSONDecoder().decode(RPCRequest.self, from: data) else {
        respond(RPCResponse(error: RPCErrorObject(code: -32700, message: "parse error")))
        continue
    }

    switch request.method {
    case "initialize":
        var clientVersion: String?
        if case .string(let value)? = request.params?["protocolVersion"] { clientVersion = value }
        respond(RPCResponse(id: request.id, result: initializeResult(clientVersion: clientVersion)))
    case "notifications/initialized", "notifications/cancelled":
        break  // notifications: no response
    case "ping":
        respond(RPCResponse(id: request.id, result: .object([:])))
    case "tools/list":
        respond(RPCResponse(id: request.id, result: .object(["tools": toolDefinitions])))
    case "tools/call":
        respond(RPCResponse(id: request.id, result: callTool(client, params: request.params)))
    default:
        if request.id != nil {
            respond(RPCResponse(
                id: request.id,
                error: RPCErrorObject(code: -32601, message: "method not found: \(request.method)")))
        }
    }
}
