import Foundation

public extension OutputItem {
    /// A message output from the model.
    struct MessageOutput: Codable, Sendable {
        /// The unique ID of the message output.
        public let id: String

        /// The role of the message output.
        public let role: Role

        /// The status of the message output.
        public let status: ResponseStatus

        /// Whether this assistant message is commentary or the final answer.
        public let phase: Response.Phase?

        /// The content of the message output.
        public let content: [MessageContent]

        public init(
            id: String,
            role: Role,
            status: ResponseStatus,
            phase: Response.Phase? = nil,
            content: [MessageContent]
        ) {
            self.id = id
            self.role = role
            self.status = status
            self.phase = phase
            self.content = content
        }

        /// An annotation in the text content.
        public struct Annotation: Codable, Sendable {
            /// The type of annotation.
            public let type: String

            /// The starting index in the text where this annotation applies.
            public let startIndex: Int

            /// The ending index in the text where this annotation applies.
            public let endIndex: Int

            /// The URL being cited (for url_citation type).
            public let url: URL

            /// The title of the cited URL (for url_citation type).
            public let title: String
        }
    }

    /// The content of a message output.
    enum MessageContent: Codable, Sendable {
        /// Text output from the model.
        case outputText(OutputText)

        // MARK: - Codable

        private enum CodingKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)

            switch type {
                case "output_text":
                    self = try .outputText(OutputText(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: container,
                        debugDescription: "Unknown message content type: \(type)"
                    )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
                case let .outputText(outputText):
                    try container.encode("output_text", forKey: .type)
                    try outputText.encode(to: encoder)
            }
        }
    }

    /// Text output from the model.
    struct OutputText: Codable, Sendable {
        /// The text content.
        public let text: String

        /// Annotations for the text content.
        public let annotations: [MessageOutput.Annotation]

        /// Optional token-level log probability data.
        public let logprobs: [Logprob]?

        private enum CodingKeys: String, CodingKey {
            case text
            case annotations
            case logprobs
        }

        public init(
            text: String,
            annotations: [MessageOutput.Annotation],
            logprobs: [Logprob]? = nil
        ) {
            self.text = text
            self.annotations = annotations
            self.logprobs = logprobs
        }

        public struct Logprob: Codable, Sendable {
            public let token: String
            public let bytes: [Int]
            public let logprob: Double
            public let topLogprobs: [TopLogprob]
        }

        public struct TopLogprob: Codable, Sendable {
            public let token: String
            public let bytes: [Int]
            public let logprob: Double
        }
    }
}
