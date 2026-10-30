import ArgumentParser
import Foundation
import Providers

/// The dry-run listing of one request.
private struct DryRun: Encodable {
    var endpoint: String
    var request: ImageRequest
    var images: [String]?
    var mask: String?
    var outputs: [String]
}

private func makeClient(_ run: RunOptions) throws -> OpenAI {
    OpenAI(credential: Credential.bearer(try Credentials.apiKey(file: run.apiKeyFile)))
}

private func printDryRun(_ dryRun: DryRun, json: Bool) throws {
    if json {
        try Output.printJSON(dryRun)
        return
    }
    print(dryRun.endpoint)
    if let images = dryRun.images { print("images: \(images.joined(separator: ", "))") }
    if let mask = dryRun.mask { print("mask: \(mask)") }
    print(String(data: try dryRun.request.jsonData(), encoding: .utf8) ?? "")
    for path in dryRun.outputs { print("would write \(path)") }
}

private func finish(_ result: ImageResult, paths: [String], json: Bool) throws {
    let report = Output.report(result, files: try Output.write(result, to: paths))
    if json { try Output.printJSON(report) } else { Output.printSummary(report) }
}

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate images from a prompt.")

    @OptionGroup var prompt: PromptOptions
    @OptionGroup var options: RequestOptions
    @OptionGroup var run: RunOptions

    func run() async throws {
        let request = try options.apply(to: ImageRequest(prompt: prompt.resolve(required: true)))
        let notes = try request.validate()
        let paths = Output.paths(base: run.out, n: request.n, format: request.outputFormat)
        try Output.checkWritable(paths, force: run.force)

        if run.dryRun {
            let plan = DryRun(endpoint: "POST /v1/images/generations", request: request, outputs: paths)
            try printDryRun(plan, json: run.json)
            return
        }
        var result = try await makeClient(run).generateImages(request)
        result.notes = notes
        try finish(result, paths: paths, json: run.json)
    }
}

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Edit images, or combine reference images, with a prompt."
    )

    @Option(name: .customLong("image"), help: "A reference image; repeat for several.")
    var images: [String] = []

    @Option(help: "A mask for the first image (prompt-guided).")
    var mask: String?

    @OptionGroup var prompt: PromptOptions
    @OptionGroup var options: RequestOptions
    @OptionGroup var run: RunOptions

    func run() async throws {
        guard !images.isEmpty else { throw ValidationError("Give at least one --image.") }
        let request = try options.apply(to: ImageRequest(prompt: prompt.resolve(required: true)))
        let notes = try request.validate()
        let paths = Output.paths(base: run.out, n: request.n, format: request.outputFormat)
        try Output.checkWritable(paths, force: run.force)

        if run.dryRun {
            try printDryRun(
                DryRun(endpoint: "POST /v1/images/edits", request: request, images: images, mask: mask, outputs: paths),
                json: run.json
            )
            return
        }
        let edit = try ImageEditRequest(
            request: request,
            images: images.map(Self.load),
            mask: mask.map(Self.load)
        )
        var result = try await makeClient(run).editImages(edit)
        result.notes = notes
        try finish(result, paths: paths, json: run.json)
    }

    private static func load(_ path: String) throws -> ImageInput {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ValidationError("Cannot read image \(path).")
        }
        return ImageInput(data: data, filename: (path as NSString).lastPathComponent)
    }
}

/// The `--dry-run --json` plan of a batch.
private struct BatchDryRun: Encodable {
    struct Job: Encodable {
        var index: Int
        var plan: DryRun?
        var error: String?
    }

    var jobs: [Job]
}

/// The `--json` result of a batch.
private struct BatchReport: Encodable {
    struct Job: Encodable {
        var index: Int
        var status: String
        var report: RunReport?
        var error: String?
    }

    var jobs: [Job]
}

struct GenerateBatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-batch",
        abstract: "Run many generate jobs from a JSONL file.",
        discussion: """
        Each line is a generate job: {"prompt": "…", "model": "…", "size": "…", "quality": "…", \
        "background": "…", "output_format": "…", "output_compression": 80, "moderation": "…", \
        "n": 1, "out": "path.png"}. Fields a line omits come from the command-line defaults.
        """
    )

    @Option(help: "The JSONL file of jobs.")
    var jobs: String

    @Option(help: "How many jobs run at once.")
    var concurrency = 4

    @Option(name: .customLong("out-dir"), help: "Directory for jobs without an `out` (job-001.png, …).")
    var outDir = Output.defaultDirectory

    @OptionGroup var prompt: PromptOptions
    @OptionGroup var options: RequestOptions
    @OptionGroup var run: RunOptions

    func run() async throws {
        guard concurrency >= 1 else { throw ValidationError("--concurrency must be at least 1.") }
        guard let text = try? String(contentsOfFile: jobs, encoding: .utf8) else {
            throw ValidationError("Cannot read --jobs \(jobs).")
        }
        let defaults = try options.apply(to: ImageRequest(prompt: prompt.resolve(required: false)))
        let parsed = try ImageBatchJob.parse(jsonl: text, defaults: defaults)
        guard !parsed.isEmpty else { throw ValidationError("\(jobs) holds no jobs.") }

        var claimed = Set<String>()
        let plans: [Result<[String], any Error>] = parsed.enumerated().map { index, job in
            let paths = Output.paths(
                base: job.out,
                directory: outDir,
                stem: String(format: "job-%03d", index + 1),
                n: job.request.n,
                format: job.request.outputFormat
            )
            return Result {
                try job.request.validate()
                try Output.checkWritable(paths, force: run.force)
                if let duplicate = paths.first(where: { claimed.contains($0) }) {
                    throw OutputError.exists("\(duplicate) (another job in this batch writes it)")
                }
                claimed.formUnion(paths)
                return paths
            }
        }

        if run.dryRun {
            var planned: [BatchDryRun.Job] = []
            for (index, job) in parsed.enumerated() {
                switch plans[index] {
                    case let .success(paths):
                        let plan = DryRun(
                            endpoint: "POST /v1/images/generations",
                            request: job.request,
                            outputs: paths
                        )
                        planned.append(.init(index: index + 1, plan: plan, error: nil))
                    case let .failure(error):
                        planned.append(.init(index: index + 1, plan: nil, error: error.localizedDescription))
                }
            }
            if run.json {
                try Output.printJSON(BatchDryRun(jobs: planned))
            } else {
                for job in planned {
                    print("job \(job.index):")
                    if let plan = job.plan {
                        try printDryRun(plan, json: false)
                    } else if let error = job.error {
                        print("  would fail: \(error)")
                    }
                }
            }
            return
        }

        let client = try makeClient(run)
        let reports = ReportBox()
        let results = await client.generateImageBatch(parsed, concurrency: concurrency) { index, job in
            let paths = try plans[index].get()
            let result = try await client.generateImages(job.request)
            await reports.set(index, Output.report(result, files: try Output.write(result, to: paths)))
            return result
        }

        var entries: [BatchReport.Job] = []
        for result in results {
            switch result.outcome {
                case .success:
                    let report = await reports.get(result.index)
                    entries.append(.init(index: result.index + 1, status: "ok", report: report, error: nil))
                    if !run.json, let report {
                        print("job \(result.index + 1): ok")
                        Output.printSummary(report)
                    }
                case let .failure(error):
                    entries.append(.init(
                        index: result.index + 1, status: "error", report: nil, error: error.localizedDescription
                    ))
                    if !run.json { print("job \(result.index + 1): failed: \(error.localizedDescription)") }
            }
        }
        if run.json { try Output.printJSON(BatchReport(jobs: entries)) }
        let failed = entries.filter { $0.status == "error" }.count
        if failed > 0 {
            FileHandle.standardError.write(Data("\(failed) of \(entries.count) jobs failed.\n".utf8))
            throw ExitCode.failure
        }
    }
}

private actor ReportBox {
    private var reports: [Int: RunReport] = [:]
    func set(_ index: Int, _ report: RunReport) { reports[index] = report }
    func get(_ index: Int) -> RunReport? { reports[index] }
}
