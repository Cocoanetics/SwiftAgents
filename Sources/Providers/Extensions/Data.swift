//
//  Data.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    init(url: URL, filename: String? = nil, purpose: String? = nil, boundary: String) throws {
        let fileData = try Data(contentsOf: url)
        let filename = filename ?? url.lastPathComponent
        let mimeType = url.mimeType()
        try self.init(data: fileData, filename: filename, mimeType: mimeType, purpose: purpose, boundary: boundary)
    }

    init(data fileData: Data, filename: String, mimeType: String, purpose: String? = nil, boundary: String) throws {
        var body = Data()

        // Add the purpose part (OpenAI requires it; Anthropic's Files API has no
        // purpose field, so it's omitted when nil).
        if let purpose {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n")
            body.append("\(purpose)\r\n")
        }

        // Add the file part
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")

        body.append("--\(boundary)--\r\n")
        self = body
    }
}
