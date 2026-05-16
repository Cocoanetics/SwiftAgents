import Foundation

public struct GoogleFile: Codable, Sendable {
    public let name: String?
    public let displayName: String?
    public let mimeType: String?
    public let sizeBytes: Int?
    public let createTime: Date?
    public let updateTime: Date?
    public let expirationTime: Date?
    public let sha256Hash: String?
    public let uri: String?
    public let state: String?
    public let source: String?

    public init(
        name: String?,
        displayName: String?,
        mimeType: String?,
        sizeBytes: Int?,
        createTime: Date?,
        updateTime: Date?,
        expirationTime: Date?,
        sha256Hash: String?,
        uri: String?,
        state: String?,
        source: String?
    ) {
        self.name = name
        self.displayName = displayName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.createTime = createTime
        self.updateTime = updateTime
        self.expirationTime = expirationTime
        self.sha256Hash = sha256Hash
        self.uri = uri
        self.state = state
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case displayName
        case mimeType
        case sizeBytes
        case createTime
        case updateTime
        case expirationTime
        case sha256Hash
        case uri
        case state
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        if let sizeString = try container.decodeIfPresent(String.self, forKey: .sizeBytes) {
            sizeBytes = Int(sizeString)
        } else {
            sizeBytes = nil
        }
        let createString = try container.decodeIfPresent(String.self, forKey: .createTime)
        createTime = GoogleFile.date(from: createString)
        let updateString = try container.decodeIfPresent(String.self, forKey: .updateTime)
        updateTime = GoogleFile.date(from: updateString)
        let expirationString = try container.decodeIfPresent(String.self, forKey: .expirationTime)
        expirationTime = GoogleFile.date(from: expirationString)
        sha256Hash = try container.decodeIfPresent(String.self, forKey: .sha256Hash)
        uri = try container.decodeIfPresent(String.self, forKey: .uri)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(mimeType, forKey: .mimeType)
        if let sizeBytes {
            try container.encode(String(sizeBytes), forKey: .sizeBytes)
        }
        try container.encode(GoogleFile.string(from: createTime), forKey: .createTime)
        try container.encode(GoogleFile.string(from: updateTime), forKey: .updateTime)
        try container.encode(GoogleFile.string(from: expirationTime), forKey: .expirationTime)
        try container.encode(sha256Hash, forKey: .sha256Hash)
        try container.encode(uri, forKey: .uri)
        try container.encode(state, forKey: .state)
        try container.encode(source, forKey: .source)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601WithoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return iso8601WithFractional.date(from: string) ?? iso8601WithoutFractional.date(from: string)
    }

    private static func string(from date: Date?) -> String? {
        guard let date else { return nil }
        return iso8601WithFractional.string(from: date)
    }
}

struct GoogleFileUploadResponse: Codable {
    let file: GoogleFile
}

struct GoogleFileListResponse: Codable {
    let files: [GoogleFile]?
}
