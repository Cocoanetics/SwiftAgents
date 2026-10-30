//
//  ImageBatch.swift
//
//  Run many generate jobs from JSONL with bounded concurrency.
//

import Foundation

/// One generate job of a batch.
public struct ImageBatchJob: Sendable {
    public var request: ImageRequest
    /// The caller's output name for this job (opaque to the client).
    public var out: String?

    public init(request: ImageRequest, out: String? = nil) {
        self.request = request
        self.out = out
    }

    private struct Line: Decodable {
        var prompt: String?
        var model: ImageModel?
        var size: ImageSize?
        var quality: ImageQuality?
        var background: ImageBackground?
        var outputFormat: ImageOutputFormat?
        var outputCompression: Int?
        var moderation: ImageModeration?
        var n: Int?
        var user: String?
        var out: String?
    }

    /// Parses JSONL: one generate job per line, each with its own `prompt`, `model`,
    /// `size`, `quality`, `background`, `output_format`, `output_compression`,
    /// `moderation`, `n`, `user` and `out`. Anything a line omits comes from `defaults`
    /// (whose `prompt` is used for lines without one). Blank lines and `#` comments are skipped.
    public static func parse(jsonl: String, defaults: ImageRequest) throws -> [ImageBatchJob] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var jobs: [ImageBatchJob] = []
        for (index, rawLine) in jsonl.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let number = index + 1
            let decoded: Line
            do {
                decoded = try decoder.decode(Line.self, from: Data(line.utf8))
            } catch {
                throw ImageGenerationError.invalidParameter(
                    "jobs line \(number): not a valid job (\(error.localizedDescription))"
                )
            }
            var request = defaults
            if let prompt = decoded.prompt { request.prompt = prompt }
            guard !request.prompt.isEmpty else {
                throw ImageGenerationError.invalidParameter("jobs line \(number): missing prompt")
            }
            if let model = decoded.model { request.model = model }
            if let size = decoded.size { request.size = size }
            if let quality = decoded.quality { request.quality = quality }
            if let background = decoded.background { request.background = background }
            if let format = decoded.outputFormat { request.outputFormat = format }
            if let compression = decoded.outputCompression { request.outputCompression = compression }
            if let moderation = decoded.moderation { request.moderation = moderation }
            if let n = decoded.n { request.n = n }
            if let user = decoded.user { request.user = user }
            jobs.append(ImageBatchJob(request: request, out: decoded.out))
        }
        return jobs
    }
}

/// The result of one batch job.
public struct ImageBatchResult: Sendable {
    /// Position of the job in the input.
    public var index: Int
    public var job: ImageBatchJob
    public var outcome: Result<ImageResult, any Error>
}

public extension OpenAI {
    /// Runs generate jobs, at most `concurrency` at a time. A failing job does not stop
    /// the others; every job gets a result, returned in input order.
    func generateImageBatch(_ jobs: [ImageBatchJob], concurrency: Int = 4) async -> [ImageBatchResult] {
        await generateImageBatch(jobs, concurrency: concurrency) { _, job in
            try await self.generateImages(job.request)
        }
    }

    /// The scheduler behind ``generateImageBatch(_:concurrency:)`` with the per-job work
    /// supplied by the caller, for example to write each image out as soon as it arrives.
    func generateImageBatch(
        _ jobs: [ImageBatchJob],
        concurrency: Int,
        run: @escaping @Sendable (_ index: Int, _ job: ImageBatchJob) async throws -> ImageResult
    ) async -> [ImageBatchResult] {
        let limit = max(1, concurrency)
        return await withTaskGroup(of: ImageBatchResult.self) { group in
            var results: [ImageBatchResult] = []
            var next = 0

            func addNext() {
                guard next < jobs.count else { return }
                let index = next
                let job = jobs[index]
                next += 1
                group.addTask {
                    do {
                        return ImageBatchResult(index: index, job: job, outcome: .success(try await run(index, job)))
                    } catch {
                        return ImageBatchResult(index: index, job: job, outcome: .failure(error))
                    }
                }
            }

            for _ in 0..<min(limit, jobs.count) { addNext() }
            while let result = await group.next() {
                results.append(result)
                addNext()
            }
            return results.sorted { $0.index < $1.index }
        }
    }
}
