import Foundation

private let maxOutputBytes = 51_200  // 50KB
private let maxOutputLines = 2_000

extension String {
	/// Truncate output to stay within token-friendly limits.
	func truncatedForToolOutput() -> String {
		let lines = self.components(separatedBy: "\n")
		var result = [String]()
		var bytes = 0

		for line in lines.prefix(maxOutputLines) {
			let lineBytes = line.utf8.count + 1
			if bytes + lineBytes > maxOutputBytes { break }
			result.append(line)
			bytes += lineBytes
		}

		if result.count < lines.count {
			let remaining = lines.count - result.count
			result.append("... (\(remaining) more lines)")
		}

		return result.joined(separator: "\n")
	}
}
