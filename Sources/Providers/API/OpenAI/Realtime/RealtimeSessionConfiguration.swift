import Foundation

public struct RealtimeSessionConfiguration: Codable, Sendable {
    public struct Prompt: Codable, Sendable {
        public var id: String
        public var version: String?
        public var variables: [String: String]?

        public init(id: String, version: String? = nil, variables: [String: String]? = nil) {
            self.id = id
            self.version = version
            self.variables = variables
        }
    }

    public enum SessionType: String, Codable, Sendable {
        case realtime
    }

    public enum OutputModality: String, Codable, Sendable {
        case text
        case audio
    }

    public enum MaxOutputTokens: Codable, Sendable {
        case finite(Int)
        case inf

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                self = .finite(intValue)
                return
            }

            let stringValue = try container.decode(String.self)
            guard stringValue == "inf" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported max_output_tokens value: \(stringValue)"
                )
            }
            self = .inf
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()

            switch self {
                case let .finite(value):
                    try container.encode(value)
                case .inf:
                    try container.encode("inf")
            }
        }
    }

    public struct Audio: Codable, Sendable {
        public struct Format: Codable, Sendable {
            public var type: String
            public var rate: Int?

            public init(type: String = "audio/pcm", rate: Int? = 24000) {
                self.type = type
                self.rate = rate
            }
        }

        public struct Input: Codable, Sendable {
            public struct NoiseReduction: Codable, Sendable {
                public var type: String?

                public init(type: String? = nil) {
                    self.type = type
                }
            }

            public struct TurnDetection: Codable, Sendable {
                public var type: String
                public var threshold: Double?
                public var prefixPaddingMs: Int?
                public var silenceDurationMs: Int?
                public var idleTimeoutMs: Int?
                public var createResponse: Bool?
                public var interruptResponse: Bool?

                public init(
                    type: String = "server_vad",
                    threshold: Double? = nil,
                    prefixPaddingMs: Int? = nil,
                    silenceDurationMs: Int? = nil,
                    idleTimeoutMs: Int? = nil,
                    createResponse: Bool? = nil,
                    interruptResponse: Bool? = nil
                ) {
                    self.type = type
                    self.threshold = threshold
                    self.prefixPaddingMs = prefixPaddingMs
                    self.silenceDurationMs = silenceDurationMs
                    self.idleTimeoutMs = idleTimeoutMs
                    self.createResponse = createResponse
                    self.interruptResponse = interruptResponse
                }
            }

            public struct Transcription: Codable, Sendable {
                public var model: String
                public var language: String?
                public var prompt: String?

                public init(model: String, language: String? = nil, prompt: String? = nil) {
                    self.model = model
                    self.language = language
                    self.prompt = prompt
                }
            }

            public var format: Format?
            public var turnDetection: TurnDetection?
            public var transcription: Transcription?
            public var noiseReduction: NoiseReduction?

            public init(
                format: Format? = nil,
                turnDetection: TurnDetection? = nil,
                transcription: Transcription? = nil,
                noiseReduction: NoiseReduction? = nil
            ) {
                self.format = format
                self.turnDetection = turnDetection
                self.transcription = transcription
                self.noiseReduction = noiseReduction
            }
        }

        public struct Output: Codable, Sendable {
            public var format: Format?
            public var voice: String?
            public var speed: Double?

            public init(format: Format? = nil, voice: String? = nil, speed: Double? = nil) {
                self.format = format
                self.voice = voice
                self.speed = speed
            }
        }

        public var input: Input?
        public var output: Output?

        public init(input: Input? = nil, output: Output? = nil) {
            self.input = input
            self.output = output
        }
    }

    public var type: SessionType
    public var audio: Audio?
    public var object: String?
    public var id: String?
    public var include: [String]?
    public var instructions: String?
    public var maxOutputTokens: MaxOutputTokens?
    public var model: String?
    public var outputModalities: [OutputModality]?
    public var prompt: Prompt?
    public var truncation: String?
    public var toolChoice: ToolChoice?
    public var tools: [Tool]?
    public var expiresAt: TimeInterval?

    public init(
        type: SessionType = .realtime,
        audio: Audio? = nil,
        object: String? = nil,
        id: String? = nil,
        include: [String]? = nil,
        instructions: String? = nil,
        maxOutputTokens: MaxOutputTokens? = nil,
        model: String? = nil,
        outputModalities: [OutputModality]? = nil,
        prompt: Prompt? = nil,
        truncation: String? = nil,
        toolChoice: ToolChoice? = nil,
        tools: [Tool]? = nil,
        expiresAt: TimeInterval? = nil
    ) {
        self.type = type
        self.audio = audio
        self.object = object
        self.id = id
        self.include = include
        self.instructions = instructions
        self.maxOutputTokens = maxOutputTokens
        self.model = model
        self.outputModalities = outputModalities
        self.prompt = prompt
        self.truncation = truncation
        self.toolChoice = toolChoice
        self.tools = tools
        self.expiresAt = expiresAt
    }

    var sendableUpdatePayload: RealtimeSessionConfiguration {
        var copy = self
        copy.object = nil
        copy.id = nil
        copy.expiresAt = nil
        copy.model = nil
        return copy
    }
}
