// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "SwiftAgents",
	platforms: [
		.macOS(.v14),
		.iOS(.v17),
		.watchOS(.v10)
	],
	products: [
		// The headline library: Agent / Runner / Tool / Responses /
		// OpenAI client. Module name is `AgentCorp` for now so existing
		// consumers (iBash) keep their `import AgentCorp` lines.
		.library(
			name: "AgentCorp",
			targets: ["AgentCorp"]
		),
		// Legacy alias — same target, kept so the old `AgentCorpCore`
		// product name resolves while consumers migrate to `AgentCorp`.
		.library(
			name: "AgentCorpCore",
			targets: ["AgentCorp"]
		),
		// Reusable ANSI/terminal helpers used by the Coder CLI. Exposed
		// as a public product so other CLI tools in the ecosystem can
		// reach for them without re-implementing colour handling.
		.library(
			name: "TerminalUI",
			targets: ["TerminalUI"]
		),
		// `coder` — in-process coding-agent CLI. Mirrors the agent
		// surface used by iBash but shells out via `Process` (so it's
		// macOS/Linux-only by construction).
		.executable(
			name: "Coder",
			targets: ["Coder"]
		)
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
		.package(url: "https://github.com/Cocoanetics/SwiftMCP", from: "1.4.4"),
		.package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.1.0"),
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
	],
	targets: [
		.target(
			name: "AgentCorp",
			dependencies: [
				"SwiftMCP",
				.product(name: "Logging", package: "swift-log")
			],
			path: "Sources/AgentCorp/Core"
		),
		.target(
			name: "TerminalUI",
			dependencies: [],
			path: "Sources/TerminalUI"
		),
		.executableTarget(
			name: "Coder",
			dependencies: [
				"AgentCorp",
				"TerminalUI",
				"SwiftMCP",
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
				.product(name: "SwiftDotenv", package: "swift-dotenv")
			],
			path: "Sources/Coder"
		),
		.testTarget(
			name: "AgentCorpTests",
			dependencies: [
				"AgentCorp",
				"SwiftMCP",
				.product(name: "SwiftDotenv", package: "swift-dotenv")
			],
			path: "Tests/AgentCorpTests",
			resources: [.process("Resources")]
		)
	]
)
