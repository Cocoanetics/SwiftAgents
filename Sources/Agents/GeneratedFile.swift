//
//  GeneratedFile.swift
//  SwiftAgents
//
//  Library-owned carrier for binary output an agent produces — currently
//  generated images, but the `mimeType` already distinguishes future inline
//  modalities (audio, video, documents) so they share one type.
//

import Foundation
import Providers

/// A binary artifact produced by an agent run, such as a generated image.
///
/// Used as an `Agent.OutputType`: when an agent's output type is
/// `GeneratedFile`, `Runner` intercepts the model's image output and returns
/// the bytes directly as `RunResult.finalOutput` — the same special-case path
/// `String` output takes — so the `Decodable` conformance required by the
/// `Agent.OutputType` constraint is never actually exercised.
public struct GeneratedFile: Decodable, Sendable, Equatable {
    /// The raw bytes of the artifact.
    public let data: Data

    /// The MIME type of the artifact, e.g. `image/png`.
    public let mimeType: String

    /// The provider-side identifier of the artifact, when one exists. For the
    /// OpenAI Responses image tool this is the `image_generation_call` ID,
    /// which can be passed back on a later turn to refer to or edit the image
    /// by ID alone. Nil for providers that don't surface an ID.
    public let id: String?

    public init(data: Data, mimeType: String, id: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.id = id
    }
}

public extension Sequence where Element == OutputItem {
    /// The first image produced by the built-in `image_generation` tool in
    /// these output items, surfaced as a `GeneratedFile`. Nil if none carries
    /// image bytes.
    var firstGeneratedFile: GeneratedFile? {
        lazy.compactMap { item -> GeneratedFile? in
            guard case let .imageGenerationCall(call) = item, let bytes = call.result else { return nil }
            return GeneratedFile(data: bytes, mimeType: call.mimeType, id: call.id)
        }.first
    }
}
