// The range of lines Replay loops over: ⌘S marks the playing line as its start and ⌘E as its end.
// Kept as times, not rows, so it survives the Lines menu rebuilding the lines.
import Foundation

struct PlayRange {
    var start: Double?  // the start line's start time
    var end: Double?    // the end line's end time

    var isEmpty: Bool { start == nil && end == nil }

    /// Makes `line` the start, unless it starts at or after the end; returns false if refused.
    mutating func setStart(_ line: CaptionLine) -> Bool {
        if let end, line.start >= end { return false }
        start = line.start
        return true
    }

    /// Makes `line` the end, unless it ends at or before the start; returns false if refused.
    mutating func setEnd(_ line: CaptionLine) -> Bool {
        if let start, line.end <= start { return false }
        end = line.end
        return true
    }

    /// Whether `line` is in the range: it overlaps start..<end, or, with only one end set, it's the
    /// line that end was taken from.
    func contains(_ line: CaptionLine) -> Bool {
        switch (start, end) {
        case let (start?, end?): return line.start < end && line.end > start
        case let (start?, nil): return line.start <= start && start < line.end
        case let (nil, end?): return line.start < end && end <= line.end
        case (nil, nil): return false
        }
    }

    /// Whether playing on from `from` to `to` ran past the end of a range with both ends set.
    /// E.g. with end 19: 18.9 → 19.05 did; 19.5 → 19.6 (already past) and 18 → 18.1 didn't.
    func ranPastEnd(from: Double, to: Double) -> Bool {
        guard start != nil, let end else { return false }
        return from < end && to >= end
    }
}
