// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The helper's Info.plist is embedded into the binary's __TEXT section so the
// LaunchAgent-executed binary carries its own CFBundleIdentifier (the stable TCC
// client identity) and usage strings. Path is computed at package-evaluation time.
let helperInfoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/apple-bridge-helper/Info.plist")
    .path

// No external dependencies. The official MCP Swift SDK (modelcontextprotocol/
// swift-sdk) was evaluated and dropped for now: this toolchain's SwiftPM cannot
// clone any git dependency (see AGENTS.md "Known toolchain issue"), and the SDK
// pulls eventsource → swift-nio → async-http-client. The MCP stdio transport is
// line-delimited JSON-RPC, which Sources/apple-bridge-mcp implements directly in
// ~200 lines. Revisit the SDK when SwiftPM fetching works.

let package = Package(
    name: "apple-bridge",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared wire types plus the pure logic that is testable without EventKit
        // (socket builder, writeAll, rules, deadline). No EventKit here — the
        // privacy API stays out of everything except the helper target (see README).
        .target(
            name: "AppleBridgeProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "apple-bridge-helper",
            dependencies: ["AppleBridgeProtocol"],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", helperInfoPlist,
                ])
            ]
        ),
        .executableTarget(
            name: "apple-bridge-mcp",
            dependencies: ["AppleBridgeProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AppleBridgeProtocolTests",
            dependencies: ["AppleBridgeProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
