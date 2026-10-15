// Test driver for ui/Lines.swift, built by tests/test_lines.py:
//   stdin  {"lines": [{"start", "end", "text", "mic"?}, ...], "seconds": 3}   ("seconds" may be null)
//   stdout regroup's lines, as the same JSON array
import Foundation

struct Input: Decodable {
    let lines: [CaptionLine]
    let seconds: Double?
}

let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
FileHandle.standardOutput.write(try JSONEncoder().encode(regroup(input.lines, seconds: input.seconds)))
