// Test driver for LeftOff in ui/LeftOff.swift, built by tests/test_left_off.py:
//   left_off_driver <prefs file>   with a JSON list of commands on stdin:
//     ["save", <folder>, <time>, <duration>]   ["time", <folder>]   ["prune"]
// Prints a JSON list with each "time" answer (null when there's none).
// The prefs file is a plist path, so the user's real preferences are never touched.
import Foundation

let leftOff = LeftOff(store: UserDefaults(suiteName: CommandLine.arguments[1])!)
let commands = try! JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[Any]]
var answers: [Any] = []
for command in commands {
    switch command[0] as! String {
    case "save":
        leftOff.save(command[2] as! Double, duration: command[3] as! Double,
                     for: URL(fileURLWithPath: command[1] as! String))
    case "time":
        answers.append(leftOff.time(for: URL(fileURLWithPath: command[1] as! String)) ?? NSNull())
    default:
        leftOff.prune()
    }
}
print(String(data: try! JSONSerialization.data(withJSONObject: answers), encoding: .utf8)!)
