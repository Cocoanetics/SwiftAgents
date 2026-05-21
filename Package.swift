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
		// LLM provider clients (OpenAI / Gemini / Ollama) plus the
		// Agent runtime that's built on top of them. Eventually the
		// runtime will move to its own target (`Agents`) and this
		// will contain only the wire-level clients. Cross-platform.
		.library(
			name: "Providers",
			targets: ["Providers"]
		),
		// In-memory vector store, Accelerate-backed vector math, and
		// the `NLContextualEmbedding`-based local embedding provider.
		// Apple-only — each file is wrapped in `#if canImport(NaturalLanguage)`,
		// so the target compiles to nothing on Linux. Opt-in: consumers
		// that don't need local embedding can ignore this product.
		.library(
			name: "VectorStore",
			targets: ["VectorStore"]
		),
		// Reusable ANSI / slash-command helpers. Used by the Coder CLI
		// and exposed so other CLIs in the ecosystem can pick them up.
		.library(
			name: "TerminalUI",
			targets: ["TerminalUI"]
		),
		// `coder` — in-process coding-agent CLI. Reference consumer of
		// the Providers target.
		.executable(
			name: "Coder",
			targets: ["Coder"]
		)
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
		.package(url: "https://github.com/Cocoanetics/SwiftMCP", from: "1.4.5"),
		.package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.1.0"),
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
	],
	targets: [
		.target(
			name: "Providers",
			dependencies: [
				"SwiftMCP",
				.product(name: "Logging", package: "swift-log")
			],
			path: "Sources/Providers"
		),
		.target(
			name: "VectorStore",
			dependencies: ["Providers"],
			path: "Sources/VectorStore"
		),
		.target(
			name: "TerminalUI",
			dependencies: [],
			path: "Sources/TerminalUI"
		),
		.executableTarget(
			name: "Coder",
			dependencies: [
				"Providers",
				"TerminalUI",
				"SwiftMCP",
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
				// swift-dotenv imports `Darwin` unconditionally so it only
				// builds on Apple platforms. The CLI's `.env` loader is a
				// developer convenience; on Linux / Windows / Android the
				// env still works via plain `ProcessInfo.processInfo.environment`.
				.product(
					name: "SwiftDotenv",
					package: "swift-dotenv",
					condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS])
				)
			],
			path: "Examples/Coder"
		),
		.testTarget(
			name: "ProvidersTests",
			dependencies: [
				"Providers",
				"VectorStore",
				"SwiftMCP",
				.product(
					name: "SwiftDotenv",
					package: "swift-dotenv",
					condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS])
				)
			],
			path: "Tests/ProvidersTests",
			resources: [.process("Resources")]
		)
	]
)
