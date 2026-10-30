import Foundation
import Providers

/// A written image.
struct FileReport: Encodable {
    var path: String
    var width: Int?
    var height: Int?
    var bytes: Int
}

/// The `--json` result of one request.
struct RunReport: Encodable {
    var files: [FileReport]
    var size: String?
    var quality: String?
    var background: String?
    var outputFormat: String?
    var usage: ImageUsage?
    var notes: [String]
    var requestId: String?
}

enum Output {
    static let defaultDirectory = "output/imagegen"

    /// The paths for `n` images: `name.png`, or `name-1.png`, `name-2.png`, … when `n > 1`.
    static func paths(
        base: String?,
        directory: String = defaultDirectory,
        stem: String = "output",
        n: Int,
        format: ImageOutputFormat?
    ) -> [String] {
        let fileExtension = (format ?? .png).fileExtension
        var path = base ?? "\(directory)/\(stem)"
        if (path as NSString).pathExtension.isEmpty { path += ".\(fileExtension)" }
        guard n > 1 else { return [path] }
        let nsPath = path as NSString
        let ext = nsPath.pathExtension
        let root = nsPath.deletingPathExtension
        return (1...n).map { "\(root)-\($0).\(ext)" }
    }

    /// Fails if any path exists and `force` is off.
    static func checkWritable(_ paths: [String], force: Bool) throws {
        guard !force else { return }
        if let existing = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            throw OutputError.exists(existing)
        }
    }

    /// Writes each generated image to its path, reading the real pixel size from the bytes.
    static func write(_ result: ImageResult, to paths: [String]) throws -> [FileReport] {
        guard result.images.count == paths.count else {
            throw OutputError.countMismatch(expected: paths.count, got: result.images.count)
        }
        var reports: [FileReport] = []
        for (image, path) in zip(result.images, paths) {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try image.data.write(to: url)
            let info = ImageInfo(data: image.data)
            reports.append(FileReport(path: path, width: info?.width, height: info?.height, bytes: image.data.count))
        }
        return reports
    }

    static func report(_ result: ImageResult, files: [FileReport]) -> RunReport {
        RunReport(
            files: files,
            size: result.size,
            quality: result.quality,
            background: result.background,
            outputFormat: result.outputFormat,
            usage: result.usage,
            notes: result.notes,
            requestId: result.requestID
        )
    }

    static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        print(String(data: try encoder.encode(value), encoding: .utf8) ?? "")
    }

    static func describe(_ file: FileReport) -> String {
        let size = file.width.flatMap { width in file.height.map { "\(width)x\($0)" } } ?? "unknown size"
        return "\(file.path) (\(size))"
    }

    static func printSummary(_ report: RunReport) {
        for file in report.files { print("wrote \(describe(file))") }
        for note in report.notes { print("note: \(note)") }
        if let usage = report.usage {
            let parts = [("input", usage.inputTokens), ("output", usage.outputTokens), ("total", usage.totalTokens),
                         ("image input", usage.inputTokensDetails?.imageTokens)]
                .compactMap { name, count in count.map { "\(name) \($0)" } }
            if !parts.isEmpty { print("tokens: \(parts.joined(separator: ", "))") }
        }
    }
}

enum OutputError: LocalizedError {
    case exists(String)
    case countMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
            case let .exists(path): return "\(path) already exists; pass --force to overwrite."
            case let .countMismatch(expected, got): return "Expected \(expected) images but the API returned \(got)."
        }
    }
}
