import Foundation

// MARK: - Extensions

public extension String {
	/*
	 Generates a unique identifier for a trace.
	 
	 - Returns: A string in the format "trace_{uuid}" where uuid is a UUID with hyphens removed
	 */
	static var traceID: String {
		"trace_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
	}

	/*
	 Generates a unique identifier for a span.
	 
	 - Returns: A string in the format "span_{prefix}" where prefix is the first 24 characters of a UUID with hyphens removed
	 */
	static var spanID: String {
		let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
		let prefix = String(uuid.prefix(24))
		return "span_\(prefix)"
	}

	/*
	 Generates a unique identifier for a group.
	 
	 - Returns: A string in the format "group_{prefix}" where prefix is the first 24 characters of a UUID with hyphens removed
	 */
	static var groupID: String {
		let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
		let prefix = String(uuid.prefix(24))
		return "group_\(prefix)"
	}
} 
