//
//  ResponseError.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 15.06.23.
//

import Foundation

public struct ErrorResponse: Codable, Sendable {
    let error: ErrorDetail
}

public struct ErrorDetail: Codable, Sendable {
    public let message: String
    public let type: String
    public let param: String?
    public let code: String?

    public init(message: String, type: String, param: String? = nil, code: String? = nil) {
        self.message = message
        self.type = type
        self.param = param
        self.code = code
    }
}
