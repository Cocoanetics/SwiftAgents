import Foundation

struct GoogleErrorResponse: Codable {
	struct ErrorBody: Codable {
		let code: Int
		let message: String
		let status: String?
	}

	let error: ErrorBody
}
