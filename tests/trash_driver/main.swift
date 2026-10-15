// Test driver for Recording.putBack in ui/Recordings.swift, built by tests/test_trash.py:
//   trash_driver <trashed folder> <original folder>
// Moves the first back to the second. Prints nothing and exits 0 on success; prints the error
// and exits 1 otherwise.
import Foundation

do {
    try Recording.putBack(from: URL(fileURLWithPath: CommandLine.arguments[1]),
                          to: URL(fileURLWithPath: CommandLine.arguments[2]))
} catch {
    print(error.localizedDescription)
    exit(1)
}
