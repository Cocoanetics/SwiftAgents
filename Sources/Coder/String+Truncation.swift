import Foundation

private let maxOutputBytes = 51200 // 50KB
private let maxOutputLines = 2000

extension String {
    /// Truncate output to stay within token-friendly limits.
    func truncatedForToolOutput() -> String {
        let lines = components(separatedBy: "\n")
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
