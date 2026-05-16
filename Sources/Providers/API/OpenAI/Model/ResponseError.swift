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
	let message: String
	let type: String
	let param: String?
	let code: String?
}
