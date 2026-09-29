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

    /// Connection loss. The caller may drop the fd and try the call once more.
    /// Reads are safe to resend. Create, update, and delete are not.
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

    /// `retry` resends after a dropped connection. Pass false for a mutation:
    /// the write may already have been applied.
    func send(_ request: BridgeRequest, retry: Bool = true) throws -> BridgeResponse {
        try ensureConnected()
        do {
            return try exchange(request)
        } catch let error as MCPError where error.reconnectable {
            closeFd()
            guard retry else { throw error }
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
let serverVersion = "0.2.0"
let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
let serverInstructions =
    "This server reads and writes the macOS Reminders of the user running the process. "
    + "Call lists before using any list other than the default. "
    + "Unfiltered reminders_read returns incomplete reminders on the default list, "
    + "soonest due first, at most 50. "
    + "Use the reminder id from a read or create result for reminders_update and reminders_delete. "
    + "Do not invent ids. Delete removes the reminder from its list. "
    + "The flag cannot be read or changed. "
    + "Recurrence, alarms, tags, URLs, locations, and subtasks are unavailable."

let toolDefinitions: JSONValue = .array([
    tool(
        "lists",
        "List the user's Reminders lists. Each entry has id (an EventKit "
            + "calendarIdentifier — use this to address a list), name, and isDefault.",
        objectSchema([:])),
    tool(
        "reminders_read",
        "Read reminders from one list. Omit list for the default list. "
            + "Open reminders come back soonest due first, undated last.",
        objectSchema([
            "list": field("string", "List name or list id. Omit for the default list."),
            "status": field("string", "open, completed, or any. Defaults to open.",
                            choices: ["open", "completed", "any"]),
            "search": field("string", "Case-insensitive substring of the title or notes."),
            "due_after": field("string", "Inclusive lower due bound. A date covers that whole local day."),
            "due_before": field("string", "Inclusive upper due bound."),
            "flagged": field("boolean", "True keeps flagged reminders. False does not filter."),
            "priority": field("string", "none, low, medium, or high.",
                              choices: ["none", "low", "medium", "high"]),
            "limit": field("integer", "Page size from 1 to 100. Defaults to 50."),
        ])),
    tool(
        "reminders_create",
        "Create an incomplete reminder. Title is required. Returns the new record.",
        objectSchema([
            "title": field("string", "Reminder title."),
            "notes": field("string", "Note body. Omit for an empty note."),
            "list": field("string", "List name or list id. Omit for the default list."),
            "due": field("string", "Calendar date (all-day) or local datetime. A zoned datetime is converted."),
            "priority": field("string", "none, low, medium, or high.",
                              choices: ["none", "low", "medium", "high"]),
            "flagged": field("boolean", "Whether the new reminder is flagged. Only false is accepted."),
        ], required: ["title"])),
    tool(
        "reminders_update",
        "Patch one reminder by id. Omitted fields stay as they are.",
        objectSchema([
            "id": field("string", "Reminder id from reminders_read or reminders_create."),
            "title": field("string", "Replacement title."),
            "notes": field("string", "Replacement notes. An empty string clears the notes."),
            "list": field("string", "Move the reminder to this list name or list id."),
            "due": field("string", "Replacement due date or time."),
            "clear_due": field("boolean", "Remove the due date. Do not send this together with due."),
            "priority": field("string", "none, low, medium, or high.",
                              choices: ["none", "low", "medium", "high"]),
            "flagged": field("boolean", "Flag or unflag. EventKit cannot change the flag."),
            "completed": field("boolean", "Complete or reopen."),
        ], required: ["id"])),
    tool(
        "reminders_delete",
        "Remove one reminder from its list.",
        objectSchema([
            "id": field("string", "Reminder id from reminders_read or reminders_create."),
        ], required: ["id"])),
])

func tool(_ name: String, _ description: String, _ schema: JSONValue) -> JSONValue {
    .object([
        "name": .string(name),
        "description": .string(description),
        "inputSchema": schema,
    ])
}

func objectSchema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    var fields: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(properties),
        "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
        fields["required"] = .array(required.map(JSONValue.string))
    }
    return .object(fields)
}

func field(_ type: String, _ description: String, choices: [String]? = nil) -> JSONValue {
    var fields: [String: JSONValue] = [
        "type": .string(type),
        "description": .string(description),
    ]
    if let choices {
        fields["enum"] = .array(choices.map(JSONValue.string))
    }
    return .object(fields)
}

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
        "instructions": .string(serverInstructions),
    ])
}

struct ArgFailure: Error, CustomStringConvertible {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

struct ToolCall {
    var request: BridgeRequest
    var retry: Bool
}

func callTool(_ client: HelperClient, params: [String: JSONValue]?) -> JSONValue {
    var name = ""
    if case .string(let value)? = params?["name"] { name = value }
    do {
        let call = try toolCall(name: name, arguments: try argumentObject(params))
        let response = try client.send(call.request, retry: call.retry)
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
    } catch let error as ArgFailure {
        return toolError(error.message)
    } catch let error as MCPError {
        return toolError("could not reach the helper: \(error). "
            + "Is apple-bridge-helper running under its LaunchAgent?")
    } catch {
        return toolError("helper call failed: \(error)")
    }
}

func toolCall(name: String, arguments: [String: JSONValue]) throws -> ToolCall {
    switch name {
    case "lists":
        try rejectUnknown(arguments, allowed: [])
        return ToolCall(request: BridgeRequest(command: .lists), retry: true)
    case "reminders_read":
        try rejectUnknown(
            arguments,
            allowed: ["list", "status", "search", "due_after", "due_before", "flagged", "priority", "limit"])
        return ToolCall(
            request: BridgeRequest(
                command: .reminders,
                list: try stringField(arguments, "list"),
                status: try stringField(arguments, "status"),
                search: try stringField(arguments, "search"),
                dueAfter: try stringField(arguments, "due_after"),
                dueBefore: try stringField(arguments, "due_before"),
                priority: try stringField(arguments, "priority"),
                limit: try limitField(arguments, "limit"),
                flagged: try boolField(arguments, "flagged")),
            retry: true)
    case "reminders_create":
        try rejectUnknown(arguments, allowed: ["title", "notes", "list", "due", "priority", "flagged"])
        return ToolCall(
            request: BridgeRequest(
                command: .create,
                title: try stringField(arguments, "title") ?? "",
                notes: try stringField(arguments, "notes"),
                due: try stringField(arguments, "due"),
                list: try stringField(arguments, "list"),
                priority: try stringField(arguments, "priority"),
                flagged: try boolField(arguments, "flagged")),
            retry: false)
    case "reminders_update":
        try rejectUnknown(
            arguments,
            allowed: ["id", "title", "notes", "list", "due", "clear_due", "priority", "flagged", "completed"])
        return ToolCall(
            request: BridgeRequest(
                command: .update,
                reminderId: try stringField(arguments, "id") ?? "",
                title: try stringField(arguments, "title"),
                notes: try stringField(arguments, "notes"),
                due: try stringField(arguments, "due"),
                completed: try boolField(arguments, "completed"),
                list: try stringField(arguments, "list"),
                priority: try stringField(arguments, "priority"),
                clearDue: try boolField(arguments, "clear_due"),
                flagged: try boolField(arguments, "flagged")),
            retry: false)
    case "reminders_delete":
        try rejectUnknown(arguments, allowed: ["id"])
        return ToolCall(
            request: BridgeRequest(
                command: .delete,
                reminderId: try stringField(arguments, "id") ?? ""),
            retry: false)
    default:
        throw ArgFailure("unknown tool '\(name)'")
    }
}

func argumentObject(_ params: [String: JSONValue]?) throws -> [String: JSONValue] {
    guard let raw = params?["arguments"] else { return [:] }
    if case .null = raw { return [:] }
    guard case .object(let object) = raw else {
        throw ArgFailure("arguments must be an object.")
    }
    return object
}

func rejectUnknown(_ args: [String: JSONValue], allowed: Set<String>) throws {
    if let key = args.keys.first(where: { !allowed.contains($0) }) {
        throw ArgFailure("Unknown argument '\(key)'.")
    }
}

func stringField(_ args: [String: JSONValue], _ key: String) throws -> String? {
    guard let value = args[key] else { return nil }
    if case .null = value { return nil }
    guard case .string(let text) = value else {
        throw ArgFailure("\(key) must be a string.")
    }
    return text
}

func boolField(_ args: [String: JSONValue], _ key: String) throws -> Bool? {
    guard let value = args[key] else { return nil }
    if case .null = value { return nil }
    guard case .bool(let flag) = value else {
        throw ArgFailure("\(key) must be a boolean.")
    }
    return flag
}

func limitField(_ args: [String: JSONValue], _ key: String) throws -> Int? {
    guard let value = args[key] else { return nil }
    if case .null = value { return nil }
    guard case .number(let number) = value, number.isFinite, number == number.rounded(),
          number >= Double(Int.min), number <= Double(Int.max) else {
        throw ArgFailure(ReminderText.badLimit)
    }
    let limit = Int(number)
    guard (1...100).contains(limit) else {
        throw ArgFailure(ReminderText.badLimit)
    }
    return limit
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
