import Foundation
import Providers

/// An agent that requests specific output media (image, audio, …) from the
/// model.
///
/// Conforming agents *declare* which output modalities they want, with
/// per-modality options; the Runner *realizes* that intent per provider — the
/// OpenAI Responses `image_generation` tool, Gemini's `responseModalities` +
/// `imageConfig`, and so on. Agents that only produce text don't conform, so
/// the concept stays off types that don't need it (mirroring `AppliesPatches`).
///
/// A per-run `RunConfig.requestedMedia` overrides whatever the agent declares.
public protocol RequestsMedia {
    /// The output modalities this agent wants, in preference order.
    var requestedMedia: [RequestedMedia] { get }
}
