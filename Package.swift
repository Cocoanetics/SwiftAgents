// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Coder's ACP surface is macOS-gated in the manifest, not just in source: the
// test target depends on the `Coder` executable, whose `CodingAgent` uses
// `Foundation.Process` (absent on Android). Gating the *declaration* keeps that
// dependency edge — and Coder's build — off the Linux/Windows/Android CI jobs,
// which build with `--build-tests`. macOS runs the full suite and picks it up.
#if os(macOS)
let coderTestTargets: [Target] = [
    .testTarget(
        name: "CoderTests",
        dependencies: [
            "Coder",
            .product(name: "SwiftACP", package: "SwiftACP"),
            .product(name: "JSONFoundation", package: "JSONFoundation")
        ],
        path: "Tests/CoderTests"
    )
]
#else
let coderTestTargets: [Target] = []
#endif

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
		// LLM provider clients (OpenAI / Anthropic / Gemini / Ollama /
		// LMStudio) — wire-level only. Cross-platform.
		.library(
			name: "Providers",
			targets: ["Providers"]
		),
		// The Agent runtime (Runner, Agent / BasicAgent, Handoffs,
		// Guardrails, agent-tier Realtime) built on top of Providers.
		// Pull this in when you want the agent loop; otherwise just use
		// Providers directly.
		.library(
			name: "Agents",
			targets: ["Agents"]
		),
		// Umbrella product. `import SwiftAgents` re-exports Providers,
		// Tracing, and Agents — convenient for apps that want the whole
		// stack without listing every module.
		.library(
			name: "SwiftAgents",
			targets: ["SwiftAgents"]
		),
		// Semantic search stores: the trait-gated persistent `SQLiteVectorStore`
		// (vec0 + FTS5 hybrid) and the hosted `OpenAIVectorStore` unified behind
		// the `SemanticStore` protocol, plus the standalone in-memory
		// `LocalVectorStore` — with chunkers, query expansion, RRF, and
		// reranking. Cross-platform; the on-device `NLContextualEmbedding`
		// default embedder is Apple-only (other platforms supply a provider).
		.library(
			name: "SemanticStore",
			targets: ["SemanticStore"]
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
	// Opt-in trait gating the SQLiteKit-backed `SQLiteVectorStore`
	// (sqlite-vec `vec0` + FTS5). OFF by default so the standard build
	// stays lean and the Windows / Android jobs don't compile SQLiteKit's
	// closure. Enable with `swift build --traits SQLiteVectorStore`.
	traits: [
		.trait(
			name: "SQLiteVectorStore",
			description: "Persistent SQLite vector + full-text store (Cocoanetics/SQLiteKit)."
		)
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
		// Link only SwiftMCP's NIO-free core + the `Client` trait (the MCP
		// client we use) — NOT the `Server` HTTP transport — so swift-nio stays
		// out of SwiftAgents' graph and we build on Windows. 1.9.0+ runs the
		// client transports on JSONFoundation's shared JSON-RPC runtime. (For
		// local sibling development, override with a path dependency — but keep
		// the published URL committed so CI resolves.)
		// `.git` suffix matches SwiftACP's spelling of the same dependency —
		// mixed spellings alias to one canonical identity but SwiftPM logs an
		// info and the aliasing needlessly stresses the resolver.
		.package(url: "https://github.com/Cocoanetics/SwiftMCP.git", from: "1.9.0", traits: ["Client"]),
		// SwiftACP has no tagged release yet; pin to `main` (mirrors SQLiteKit below).
		// `traits: []` disables its default-on `Server` trait (the swift-nio
		// TCP/Bonjour/HTTP-SSE transports used only by the acpxd daemon) — Coder
		// serves ACP over stdio, and this keeps swift-nio/crypto out of the graph.
		.package(url: "https://github.com/Cocoanetics/SwiftACP", branch: "main", traits: []),
		// JSONFoundation by URL (not path) — matches SwiftMCP's and SwiftACP's
		// published remote reference to the same package identity (a path override
		// would conflict). 2.5.0 ships the JSON value type, JSON Schema model,
		// @Schema macro, and the shared JSON-RPC runtime.
		//
		// The `Subprocess` trait is anchored HERE, not just via SwiftACP: in a
		// product-scoped build (CI's `swift build --product Providers`), SwiftPM
		// prunes SwiftACP from the graph, its trait enablement flips off, and
		// the solver oscillates on swift-subprocess until it fails with
		// "exhausted attempts to resolve the dependencies graph". Enabling the
		// trait at the root keeps the dependency set stable across solver
		// iterations. It links nothing into SwiftAgents' own targets.
		.package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "2.5.0", traits: ["Subprocess"]),
		.package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.1.0"),
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
		// Cross-platform compatibility shims (URLSession.AsyncBytes / bytes(for:),
		// UTType, …) shared via SwiftCross instead of duplicated in Providers.
		.package(url: "https://github.com/Cocoanetics/SwiftCross.git", from: "1.0.0"),
		// SQLiteKit's `vec0` (sqlite-vec) + FTS5 engines back the opt-in
		// `SQLiteVectorStore`. Standalone package (extracted from SwiftPorts);
		// its only closure is the vendored CSQLite amalgamation. Pinned to
		// `main` until it tags a release. Resolved always, but only compiled
		// when the `SQLiteVectorStore` trait is on (see SemanticStore).
		.package(
			url: "https://github.com/Cocoanetics/SQLiteKit",
			branch: "main",
			traits: ["SQLiteVec", "FTS5"]
		)
	],
	targets: [
		.target(
			name: "Tracing",
			dependencies: [
				// Tracing only needs the JSON value type (span-data export), not
				// the MCP client or macros — link the lightweight, NIO-free
				// JSONFoundation product rather than the full SwiftMCP module.
				.product(name: "JSONFoundation", package: "JSONFoundation"),
				"SwiftCross"
			],
			path: "Sources/Tracing"
		),
		.target(
			name: "Providers",
			dependencies: [
				"SwiftMCP",
				"SwiftCross",
				"Tracing",
				// The JSON value + schema model used throughout the wire types.
				// Declared explicitly (not just via SwiftMCP's re-export) so the
				// pure model files can `import JSONFoundation` without coupling
				// to the MCP client module.
				.product(name: "JSONFoundation", package: "JSONFoundation"),
				// Spec-correct incremental SSE decoding for the provider
				// streaming paths — framing codec only, no transports.
				.product(name: "JSONRPCWire", package: "JSONFoundation"),
				.product(name: "Logging", package: "swift-log")
			],
			path: "Sources/Providers"
		),
		.target(
			name: "Agents",
			dependencies: [
				"Providers",
				"Tracing",
				"SwiftMCP",
				// Direct dependency for the JSON value + schema model (see
				// Providers above).
				.product(name: "JSONFoundation", package: "JSONFoundation")
			],
			path: "Sources/Agents"
		),
		.target(
			name: "SwiftAgents",
			dependencies: [
				"Providers",
				"Tracing",
				"Agents"
			],
			path: "Sources/SwiftAgents"
		),
		.target(
			name: "SemanticStore",
			dependencies: [
				"Providers",
				// Linked only when the `SQLiteVectorStore` trait is enabled,
				// so the default SemanticStore build (the local + hosted
				// stores) stays free of the SQLiteKit dependency.
				.product(
					name: "SQLiteKit",
					package: "SQLiteKit",
					condition: .when(traits: ["SQLiteVectorStore"])
				)
			],
			path: "Sources/SemanticStore"
		),
		.target(
			name: "TerminalUI",
			dependencies: [],
			path: "Sources/TerminalUI"
		),
		.executableTarget(
			name: "Coder",
			dependencies: [
				"SwiftAgents",
				"TerminalUI",
				"SwiftMCP",
				.product(name: "SwiftACP", package: "SwiftACP"),
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
				"Agents",
				"Tracing",
				"SemanticStore",
				"SwiftMCP",
				"SwiftCross"
			],
			path: "Tests/ProvidersTests",
			resources: [.process("Resources")]
		)
	] + coderTestTargets,
	// Tools 6.1 (needed for SwiftMCP package-trait selection) defaults to the
	// Swift 6 language mode; the package builds clean under full strict
	// concurrency.
	swiftLanguageModes: [.v6]
)
