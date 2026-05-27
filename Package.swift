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
		// Generic tracing primitives — TraceProvider, TraceSpan,
		// TracingProcessor, withSpan, etc. Provider-agnostic so
		// `Providers` and future targets depend on it without
		// coupling to any specific LLM backend.
		.library(
			name: "Tracing",
			targets: ["Tracing"]
		),
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
		// Pinned below 1.4.7 because that release made `mcpToolMetadata`
		// async, which breaks the synchronous call sites in
		// `Array+MCPToolProviding.swift` and `MCPToolProviding+ToolDescription.swift`.
		// Lift this once those callers are migrated to `await`.
		.package(url: "https://github.com/Cocoanetics/SwiftMCP", "1.4.5" ..< "1.4.7"),
		.package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.1.0"),
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
	],
	targets: [
		.target(
			name: "Tracing",
			dependencies: [
				"SwiftMCP"
			],
			path: "Sources/Tracing"
		),
		.target(
			name: "Providers",
			dependencies: [
				"SwiftMCP",
				"Tracing",
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
				"Tracing",
				"TerminalUI",
				"SwiftMCP",
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
				// swift-dotenv 2.1.0 supports Apple platforms (via Darwin)
				// and Linux (via Glibc), but not Windows or Android. The
				// `#if canImport(SwiftDotenv)` guard in `Coder.swift` covers
				// those — on platforms where the dep isn't linked, the CLI
				// falls back to `ProcessInfo.processInfo.environment`.
				.product(
					name: "SwiftDotenv",
					package: "swift-dotenv",
					condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux])
				)
			],
			path: "Examples/Coder"
		),
		.testTarget(
			name: "ProvidersTests",
			dependencies: [
				"Providers",
				"Tracing",
				"VectorStore",
				"SwiftMCP"
			],
			path: "Tests/ProvidersTests",
			resources: [.process("Resources")]
		)
	]
)
