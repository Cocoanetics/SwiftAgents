import Foundation
import OSLog

/// Buffers assistant transcript text and releases it into the visible entry
/// only as the corresponding audio is actually played back.
///
/// Flow:
/// 1. Transcript deltas arrive → buffered here, NOT written to the entry.
/// 2. Audio chunks arrive → total received audio duration grows.
/// 3. A timer reads playback progress (played ms / total received ms).
/// 4. The fraction maps to a character position in the buffer.
/// 5. Only that portion is written to the entry's `text`.
/// 6. On barge-in, the entry keeps exactly what was spoken + "…".
/// 7. On completion, the entry gets the full buffered text.
@MainActor
final class SpokenTextTracker {
    private static let logger = Logger(subsystem: "RealtimeVoiceAgent", category: "SpokenText")

    /// The transcript entry ID in the ViewModel's array.
    private(set) var entryID: String?
    /// The OpenAI realtime item ID for matching audio/transcript events.
    private(set) var itemID: String?
    /// Full text received from transcript deltas (may be ahead of playback).
    private(set) var bufferedText: String = ""
    /// How many characters of `bufferedText` have been shown (includes look-ahead).
    private(set) var spokenLength: Int = 0
    /// How many characters have actually been played through the speaker (no look-ahead).
    private(set) var actuallyPlayedLength: Int = 0
    /// Whether the final transcript delta has arrived.
    private(set) var isComplete: Bool = false

    /// Whether there is an active tracking session.
    var isActive: Bool { itemID != nil }

    // MARK: - Receiving transcript deltas

    /// Start tracking a new assistant audio item.
    func begin(entryID: String, itemID: String) {
        Self.logger.info("Begin tracking: entry=\(entryID, privacy: .public) item=\(itemID, privacy: .public)")
        self.entryID = entryID
        self.itemID = itemID
        self.bufferedText = ""
        self.spokenLength = 0
        self.isComplete = false
    }

    /// Append a transcript delta to the buffer.
    func appendDelta(_ text: String) {
        bufferedText += text
        Self.logger.info("Buffer: +\(text.count) chars → \(self.bufferedText.count) total, spoken=\(self.spokenLength)")
    }

    /// Replace the buffer with the final complete transcript.
    func replaceWithFinal(_ fullText: String) {
        bufferedText = fullText
        isComplete = true
        Self.logger.info("Final buffer: \(self.bufferedText.count) chars, spoken=\(self.spokenLength)")
    }

    // MARK: - Playback-synced reveal

    struct TickResult {
        let text: String
        /// How long to animate this segment appearing (matches its speaking duration).
        let animationDuration: TimeInterval
    }

    /// Compute how much text should be shown given the current playback progress.
    ///
    /// `playedMs` uses `.dataPlayedBack` so it reflects audio actually heard
    /// through the speaker.
    func tick(playedMs: Double, totalReceivedMs: Double) -> TickResult? {
        guard !bufferedText.isEmpty, totalReceivedMs > 0 else { return nil }

        let fraction = min(playedMs / totalReceivedMs, 1.0)
        let rawTarget = Int(fraction * Double(bufferedText.count))

        // Snap forward to next word boundary
        let target: Int
        if rawTarget >= bufferedText.count {
            target = bufferedText.count
        } else {
            let idx = bufferedText.index(bufferedText.startIndex, offsetBy: rawTarget)
            if let space = bufferedText[idx...].firstIndex(of: " ") {
                target = bufferedText.distance(from: bufferedText.startIndex, to: space)
            } else {
                target = rawTarget
            }
        }

        actuallyPlayedLength = target

        guard target > spokenLength else { return nil }

        spokenLength = target
        let spoken = String(bufferedText.prefix(spokenLength))
        Self.logger.info("Tick: shown=\(self.spokenLength)/\(self.bufferedText.count) fraction=\(String(format: "%.3f", fraction)) played=\(Int(playedMs))ms total=\(Int(totalReceivedMs))ms newSegment=\"\(String(spoken.suffix(40)), privacy: .public)\"")
        return TickResult(text: spoken, animationDuration: 0)
    }

    // MARK: - Interrupt / Complete

    /// Called on barge-in. Returns the actually-heard text + "…" to permanently set on the entry.
    /// Uses `actuallyPlayedLength` (not the look-ahead `spokenLength`) for accuracy.
    func interrupt() -> String? {
        guard let _ = itemID else { return nil }
        // Snap to word boundary
        let cutoff = snapToWordBoundary(actuallyPlayedLength)
        let spoken = String(bufferedText.prefix(cutoff))
        let result = cutoff < bufferedText.count ? spoken + "…" : spoken
        Self.logger.info("Interrupt: keeping \(cutoff)/\(self.bufferedText.count) chars (shown=\(self.spokenLength), played=\(self.actuallyPlayedLength))")
        reset()
        return result
    }

    private func snapToWordBoundary(_ position: Int) -> Int {
        guard position < bufferedText.count else { return bufferedText.count }
        guard position > 0 else { return 0 }
        let idx = bufferedText.index(bufferedText.startIndex, offsetBy: position)
        // Snap backward to last space so we don't cut mid-word
        if let space = bufferedText[..<idx].lastIndex(of: " ") {
            return bufferedText.distance(from: bufferedText.startIndex, to: bufferedText.index(after: space))
        }
        return position
    }

    /// Called when all audio has been played. Returns the full buffered text.
    func complete() -> String? {
        guard let _ = itemID else { return nil }
        let result = bufferedText
        Self.logger.info("Complete: revealing all \(self.bufferedText.count) chars")
        reset()
        return result
    }

    func reset() {
        entryID = nil
        itemID = nil
        bufferedText = ""
        spokenLength = 0
        actuallyPlayedLength = 0
        isComplete = false
    }
}
