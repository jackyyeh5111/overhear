// Where you stopped in each recording, so Replay can pick up there next time and Home can show it.
// Kept in the app's preferences, keyed by the recording's folder; the recordings' files are never
// touched.
import Foundation

struct LeftOff {
    let store: UserDefaults

    /// Stopping this close to either end means "not started" or "finished": nothing to remember.
    static let edge = 5.0
    private static let key = "replayLeftOff"

    private var all: [String: Double] { store.dictionary(forKey: LeftOff.key) as? [String: Double] ?? [:] }

    /// Where you stopped in the recording in `folder`, or nil if it's untouched or finished.
    func time(for folder: URL) -> Double? { all[folder.path] }

    /// Remembers `time` for the recording in `folder`, or forgets it near either end.
    /// E.g. 754 of 2700 → remembered; 3 or 2697 of 2700 → forgotten.
    func save(_ time: Double, duration: Double, for folder: URL) {
        var all = self.all
        let kept = time >= LeftOff.edge && time <= duration - LeftOff.edge
        guard all[folder.path] != (kept ? time : nil) else { return }
        all[folder.path] = kept ? time : nil
        store.set(all, forKey: LeftOff.key)
    }

    /// Forgets recordings whose folders are gone. Run at launch: Undo of Move to Trash doesn't
    /// outlive the app, so a folder missing then isn't coming back through it.
    func prune() {
        let all = self.all
        let kept = all.filter { FileManager.default.fileExists(atPath: $0.key) }
        if kept.count != all.count { store.set(kept, forKey: LeftOff.key) }
    }
}
