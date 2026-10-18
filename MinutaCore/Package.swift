// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MinutaCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MinutaCore", targets: ["MinutaCore"]),
        .library(name: "MinutaTranscription", targets: ["MinutaTranscription"]),
        .executable(name: "minuta-transcribe", targets: ["minuta-transcribe"]),
        .library(name: "MinutaMCP", targets: ["MinutaMCP"]),
        .executable(name: "minuta-mcp", targets: ["minuta-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        // Pure logic, no models: unit tested.
        .target(name: "MinutaCore"),
        // WhisperKit transcription + SpeakerKit diarization.
        .target(name: "MinutaTranscription", dependencies: [
            "MinutaCore",
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "SpeakerKit", package: "WhisperKit"),
        ]),
        // Dev tool: transcribe a recording folder from the terminal.
        .executableTarget(name: "minuta-transcribe", dependencies: ["MinutaTranscription"]),
        // MCP server (stdio) so AI assistants can list, search and read transcripts. Read-only.
        .target(name: "MinutaMCP", dependencies: [
            "MinutaCore",
            .product(name: "MCP", package: "swift-sdk"),
        ]),
        .executableTarget(name: "minuta-mcp", dependencies: ["MinutaMCP"]),
        .testTarget(name: "MinutaCoreTests", dependencies: ["MinutaCore"]),
    ]
)
