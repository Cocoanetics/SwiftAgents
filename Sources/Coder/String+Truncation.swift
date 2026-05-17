import Foundation

/// Hard cap used by the per-tool truncation helpers below — every coding
/// agent tool that returns text caps its output at this byte count so a
/// single response can't blow the model's context window.
public let toolOutputByteCap = 512 * 1024 // 512 KB

extension String {
    /// Truncate output to stay within token-friendly limits.
    ///
    /// Keeps the first `maxLines` lines (or fewer if a 512 KB byte cap
    /// is reached first). Used by tools that produce sequential output
    /// where the head is most informative (`read`, `ls`, `find`, `grep`).
    /// `bash` uses the tail-keeping variant ``truncatedForToolOutputTail``
    /// instead.
    func truncatedForToolOutput(maxLines: Int = 2000, maxBytes: Int = toolOutputByteCap) -> String {
        let lines = components(separatedBy: "\n")
        var result = [String]()
        var bytes = 0

        for line in lines.prefix(maxLines) {
            let lineBytes = line.utf8.count + 1
            if bytes + lineBytes > maxBytes { break }
            result.append(line)
            bytes += lineBytes
        }

        if result.count < lines.count {
            let remaining = lines.count - result.count
            result.append("... (\(remaining) more lines)")
        }

        return result.joined(separator: "\n")
    }

    /// Keep the *last* `maxLines` lines (or fewer if `maxBytes` hits
    /// first) — used by `bash` so a long-running command's most recent
    /// output reaches the model rather than the start of the log.
    func truncatedForToolOutputTail(maxLines: Int = 2000, maxBytes: Int = toolOutputByteCap) -> String {
        let lines = components(separatedBy: "\n")
        var kept = [String]()
        var bytes = 0

        for line in lines.suffix(maxLines).reversed() {
            let lineBytes = line.utf8.count + 1
            if bytes + lineBytes > maxBytes { break }
            kept.append(line)
            bytes += lineBytes
        }
        kept.reverse()

        if kept.count < lines.count {
            let dropped = lines.count - kept.count
            kept.insert("... (\(dropped) earlier lines truncated)", at: 0)
        }

        return kept.joined(separator: "\n")
    }
}
