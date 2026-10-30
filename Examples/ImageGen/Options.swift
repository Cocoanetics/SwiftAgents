import ArgumentParser
import Foundation
import Providers

/// The request settings shared by every subcommand.
struct RequestOptions: ParsableArguments {
    @Option(help: "Model: gpt-image-2.5-sunburst (default), gpt-image-2.5-flare, gpt-image-2, or any model name.")
    var model: String?

    @Option(help: "auto or WIDTHxHEIGHT, e.g. 2048x1152 (presets: \(SizePreset.helpList)).")
    var size: String?

    @Option(help: "low, medium, high, auto; xhigh and max on the 2.5 models only.")
    var quality: String?

    @Option(help: "auto, opaque or transparent (transparent: 2.5 models, png or webp).")
    var background: String?

    @Option(name: .customLong("output-format"), help: "png (default), jpeg or webp.")
    var outputFormat: String?

    @Option(name: .customLong("output-compression"), help: "0-100; jpeg and webp only.")
    var outputCompression: Int?

    @Option(help: "auto or low.")
    var moderation: String?

    @Option(help: "Number of images per request.")
    var n: Int?

    /// A request carrying only the options that were given, on top of `base`.
    func apply(to base: ImageRequest) throws -> ImageRequest {
        var request = base
        if let model { request.model = ImageModel(model) }
        if let size { request.size = try SizePreset.resolve(size) }
        if let quality { request.quality = ImageQuality(quality) }
        if let background {
            request.background = try Self.parse(background, as: ImageBackground.self, option: "--background")
        }
        if let outputFormat {
            request.outputFormat = try Self.parse(outputFormat, as: ImageOutputFormat.self, option: "--output-format")
        }
        if let outputCompression { request.outputCompression = outputCompression }
        if let moderation {
            request.moderation = try Self.parse(moderation, as: ImageModeration.self, option: "--moderation")
        }
        if let n { request.n = n }
        return request
    }

    private static func parse<Value: RawRepresentable & CaseIterable>(
        _ text: String,
        as _: Value.Type,
        option: String
    ) throws -> Value where Value.RawValue == String {
        guard let value = Value(rawValue: text) else {
            let allowed = Value.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("\(option) must be one of: \(allowed) (got '\(text)')")
        }
        return value
    }
}

/// Where the images go and how the command reports.
struct RunOptions: ParsableArguments {
    @Option(help: "Output file. With --n > 1, name-1.png, name-2.png, … (default: output/imagegen/output.png).")
    var out: String?

    @Flag(help: "Overwrite existing output files.")
    var force = false

    @Flag(
        name: .customLong("dry-run"),
        help: "Print the request JSON and output paths without calling the API (no key needed)."
    )
    var dryRun = false

    @Flag(help: "Print a machine-readable result: paths, sizes, resolved settings, usage.")
    var json = false

    @Option(name: .customLong("api-key-file"), help: "File holding the API key, used when OPENAI_API_KEY is not set.")
    var apiKeyFile: String?
}

/// The prompt, from `--prompt` or `--prompt-file`.
struct PromptOptions: ParsableArguments {
    @Option(help: "The prompt.")
    var prompt: String?

    @Option(name: .customLong("prompt-file"), help: "Read the prompt from this file.")
    var promptFile: String?

    func resolve(required: Bool) throws -> String {
        if prompt != nil, promptFile != nil {
            throw ValidationError("Give --prompt or --prompt-file, not both.")
        }
        if let prompt { return prompt }
        if let promptFile {
            do {
                return try String(contentsOfFile: promptFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw ValidationError("Cannot read --prompt-file \(promptFile): \(error.localizedDescription)")
            }
        }
        if required { throw ValidationError("A prompt is required: --prompt or --prompt-file.") }
        return ""
    }
}

/// Size presets: `1080p`, `1440p`, `4k` and their portrait forms.
enum SizePreset {
    private static let presets: [String: String] = [
        // 1080 isn't a multiple of 16, so 1080p rounds up to 1088.
        "1080p": "1920x1088", "1080p-portrait": "1088x1920",
        "1440p": "2560x1440", "1440p-portrait": "1440x2560",
        "4k": "3840x2160", "4k-portrait": "2160x3840"
    ]

    static var helpList: String { "1080p, 1440p, 4k, each also -portrait" }

    static func resolve(_ text: String) throws -> ImageSize {
        ImageSize(presets[text.lowercased()] ?? text)
    }
}

enum Credentials {
    /// `OPENAI_API_KEY`, otherwise the contents of `--api-key-file`.
    static func apiKey(file: String?) throws -> String {
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return key
        }
        guard let file else {
            throw ValidationError("No API key: set OPENAI_API_KEY or pass --api-key-file.")
        }
        let key: String
        do {
            key = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ValidationError("Cannot read --api-key-file \(file): \(error.localizedDescription)")
        }
        guard !key.isEmpty else { throw ValidationError("--api-key-file \(file) is empty.") }
        return key
    }
}
