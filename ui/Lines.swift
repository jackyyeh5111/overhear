// Rebuilds a transcript's lines to about N seconds each, for Replay's Lines menu: long lines are
// split and short ones merged. Captions only store each line's start and end, so a word's time is
// estimated by spreading its line's duration over the line's characters.
import Foundation

let pauseBreak = 2.0  // seconds of silence that always start a new line
private let closers = CharacterSet(charactersIn: "\"')]”’")

/// A word with its estimated time, and its line's mic flag.
struct TimedWord {
    let text: String
    let start: Double
    let end: Double
    let mic: Bool
}

/// Splits each line on whitespace and spreads its duration over its words by length, counting
/// each word as its characters plus one (for the space). E.g. 0–8 s "aaa bbbbbbb" →
/// "aaa" 0–2.67 s, "bbbbbbb" 2.67–8 s (weights 4 and 8 of 12).
func estimatedWords(_ lines: [CaptionLine]) -> [TimedWord] {
    lines.flatMap { line -> [TimedWord] in
        let words = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = Double(words.reduce(0) { $0 + $1.count + 1 })
        let perChar = (line.end - line.start) / max(1, total)
        var at = line.start
        return words.map { word in
            let start = at
            at += Double(word.count + 1) * perChar
            return TimedWord(text: word, start: start, end: at, mic: line.mic == true)
        }
    }
}

/// Lines of about `seconds` each, rebuilt from `lines`' words; nil returns `lines` unchanged.
/// A line ends at the first sentence end once it's `seconds` long, or at the first word once it's
/// 1.5 × `seconds` long. A pause of `pauseBreak` always ends it.
/// E.g. 3 s on "One two three four. Five six." spoken over 0–6 s → "One two three four." and
/// "Five six."
func regroup(_ lines: [CaptionLine], seconds: Double?) -> [CaptionLine] {
    guard let seconds else { return lines }
    var out: [CaptionLine] = []
    var chunk: [TimedWord] = []
    func flush() {
        guard let first = chunk.first, let last = chunk.last else { return }
        out.append(CaptionLine(start: first.start, end: last.end,
                               text: chunk.map(\.text).joined(separator: " "),
                               mic: chunk.contains(where: \.mic) ? true : nil))
        chunk = []
    }
    for word in estimatedWords(lines) {
        if let last = chunk.last, word.start - last.end >= pauseBreak { flush() }
        chunk.append(word)
        let length = word.end - chunk[0].start
        if length >= seconds && endsSentence(word.text) || length >= 1.5 * seconds { flush() }
    }
    flush()
    return out
}

/// Whether `word` ends in . ? or !, looking past closing quotes and brackets: `"stop."` does.
private func endsSentence(_ word: String) -> Bool {
    let core = word.trimmingCharacters(in: closers)
    return core.last.map { ".?!".contains($0) } ?? false
}
