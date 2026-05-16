import Foundation

extension ContentItem {
    /// A text output from the model.
    public struct OutputText: Codable, Sendable {
        /// The annotations of the text output.
        public let annotations: [OutputItem.MessageOutput.Annotation]

		/// Optional token-level log probability data.
		public let logprobs: [Logprob]?

        /// The text output from the model.
        public let text: String

        /// Initialize a new OutputText instance.
        /// - Parameters:
        ///   - text: The text output from the model.
        ///   - annotations: The annotations of the text output.
        public init(text: String,
					annotations: [OutputItem.MessageOutput.Annotation],
					logprobs: [Logprob]? = nil) {
            self.text = text
            self.annotations = annotations
			self.logprobs = logprobs
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case annotations
			case logprobs
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            annotations = try container.decode([OutputItem.MessageOutput.Annotation].self, forKey: .annotations)
			logprobs = try container.decodeIfPresent([Logprob].self, forKey: .logprobs)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encode(annotations, forKey: .annotations)
			try container.encodeIfPresent(logprobs, forKey: .logprobs)
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
