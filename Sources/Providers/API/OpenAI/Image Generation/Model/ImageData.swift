//
//  ImageData.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

/// Data model for generated images
public struct ImageData: Codable {
    /// The URL of the generated image
    public let url: URL?

    /// The decoded image data
    public let data: Data?

    enum CodingKeys: String, CodingKey {
        case url
        case data = "b64Json"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(URL.self, forKey: .url)

        if let base64String = try container.decodeIfPresent(String.self, forKey: .data) {
            data = Data(base64Encoded: base64String)
        } else {
            data = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(url, forKey: .url)

        if let data {
            let base64String = data.base64EncodedString()
            try container.encode(base64String, forKey: .data)
        }
    }
}
