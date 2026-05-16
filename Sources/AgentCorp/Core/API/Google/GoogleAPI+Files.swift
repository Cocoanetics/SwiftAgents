import Foundation

public extension GoogleAPI {
	func uploadFile(url: URL, filename: String? = nil, mimeType: String) async throws -> GoogleFile {
		let data = try Data(contentsOf: url)
		let resolvedName = filename ?? url.lastPathComponent
		return try await uploadFile(data: data, filename: resolvedName, mimeType: mimeType)
	}
	
	func uploadFile(data: Data, filename: String, mimeType: String) async throws -> GoogleFile {
		guard let apiKey = apiKey else {
			throw APIError.authenticationError("Missing GEMINI_API_KEY")
		}
		let startURL = endpointURL.appendingPathComponent("upload/\(versionPath)/files")
		var startRequest = URLRequest(url: startURL)
		startRequest.httpMethod = "POST"
		startRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
		startRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
		startRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
		startRequest.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
		startRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
		startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
		let metadataBody: [String: Any] = ["file": ["display_name": filename]]
		startRequest.httpBody = try JSONSerialization.data(withJSONObject: metadataBody, options: [])
		let (startData, startResponse) = try await session.data(for: startRequest)
		guard let startHTTP = startResponse as? HTTPURLResponse,
			  (200...299).contains(startHTTP.statusCode) else {
			throw googleError(from: startData, response: startResponse)
		}
		guard let uploadURLString = startHTTP.value(forHTTPHeaderField: "X-Goog-Upload-URL")?.trimmingCharacters(in: .whitespacesAndNewlines),
			  let uploadURL = URL(string: uploadURLString) else {
			throw APIError.otherError("upload", "Missing upload URL from Google response")
		}
		var uploadRequest = URLRequest(url: uploadURL)
		uploadRequest.httpMethod = "POST"
		uploadRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
		uploadRequest.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
		uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
		uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
		uploadRequest.httpBody = data
		let (responseData, uploadResponse) = try await session.data(for: uploadRequest)
		guard let uploadHTTP = uploadResponse as? HTTPURLResponse,
			  (200...299).contains(uploadHTTP.statusCode) else {
			throw googleError(from: responseData, response: uploadResponse)
		}
		let uploaded = try decoder.decode(GoogleFileUploadResponse.self, from: responseData)
		return uploaded.file
	}
	
	func listFiles() async throws -> [GoogleFile] {
		let request = try makeFilesRequest(path: "\(versionPath)/files")
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse,
			  (200...299).contains(http.statusCode) else {
			throw googleError(from: data, response: response)
		}
		let list = try decoder.decode(GoogleFileListResponse.self, from: data)
		return list.files ?? []
	}
	
	func retrieveFile(name: String) async throws -> GoogleFile {
		let request = try makeFilesRequest(path: "\(versionPath)/files/\(normalizedFileIdentifier(name))")
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse,
			  (200...299).contains(http.statusCode) else {
			throw googleError(from: data, response: response)
		}
		let file = try decoder.decode(GoogleFile.self, from: data)
		return file
	}
	
	@discardableResult
	func deleteFile(name: String) async throws -> Bool {
		var request = try makeFilesRequest(path: "\(versionPath)/files/\(normalizedFileIdentifier(name))")
		request.httpMethod = "DELETE"
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse,
			  (200...299).contains(http.statusCode) else {
			throw googleError(from: data, response: response)
		}
		return true
	}
	
	private func makeFilesRequest(path: String) throws -> URLRequest {
		guard let apiKey = apiKey else {
			throw APIError.authenticationError("Missing GEMINI_API_KEY")
		}
		let url = endpointURL.appendingPathComponent(path)
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
		return request
	}

	private func normalizedFileIdentifier(_ name: String) -> String {
		if let last = name.split(separator: "/").last {
			return String(last)
		}
		return name
	}
}
