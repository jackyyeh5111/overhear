// Test driver for ui/PlayRange.swift, built by tests/test_play_range.py:
//   stdin  [["start", line], ["end", line], ["contains", line], ["ran_past_end", from, to], ...]
//          where line is {"start", "end", "text"}
//   stdout one answer per command, as a JSON array: start / end → whether it was taken (true /
//          false), contains / ran_past_end → true / false
import Foundation

enum Arg: Decodable {
    case line(CaptionLine)
    case time(Double)
    case name(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .name(s) }
        else if let t = try? c.decode(Double.self) { self = .time(t) }
        else { self = .line(try c.decode(CaptionLine.self)) }
    }
}

let commands = try JSONDecoder().decode([[Arg]].self, from: FileHandle.standardInput.readDataToEndOfFile())
var range = PlayRange()
var answers: [Bool] = []
for command in commands {
    switch (command.first, command.dropFirst().first, command.dropFirst(2).first) {
    case (.name("start"), .line(let line)?, _): answers.append(range.setStart(line))
    case (.name("end"), .line(let line)?, _): answers.append(range.setEnd(line))
    case (.name("contains"), .line(let line)?, _): answers.append(range.contains(line))
    case (.name("ran_past_end"), .time(let from)?, .time(let to)?): answers.append(range.ranPastEnd(from: from, to: to))
    default: fatalError("bad command: \(command)")
    }
}
FileHandle.standardOutput.write(try JSONEncoder().encode(answers))
