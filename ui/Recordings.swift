// Saved recordings, as written by recording.py: one folder per session holding audio.m4a (or
// audio.wav if AAC conversion failed) and captions.json. In-progress sessions live in the
// hidden .partial folder and are never listed.
import Foundation

struct CaptionLine: Codable {
    let start: Double
    let end: Double
    let text: String
    let mic: Bool?  // true when the microphone heard speech in it; missing otherwise
}

struct Recording {
    let folder: URL
    let name: String
    let startedAt: Date
    let duration: Double
    let lines: [CaptionLine]

    var audioURL: URL {
        let m4a = folder.appendingPathComponent("audio.m4a")
        return FileManager.default.fileExists(atPath: m4a.path) ? m4a : folder.appendingPathComponent("audio.wav")
    }

    var title: String { Recording.dateFormat.string(from: startedAt) }

    /// Like `title`, but "Today 9:30 AM" / "Yesterday 4:12 PM" for recent ones.
    var relativeTitle: String { Recording.relativeDateFormat.string(from: startedAt) }

    /// The first caption, for a glance at what the recording is about.
    var preview: String? { lines.first?.text }

    /// Whether the user spoke in any line.
    var hasMic: Bool { lines.contains { $0.mic == true } }

    /// Whether `query` appears in the name or anywhere in the transcript, ignoring case and accents.
    func matches(_ query: String) -> Bool {
        query.isEmpty || name.localizedStandardContains(query)
            || lines.contains { $0.text.localizedStandardContains(query) }
    }

    /// Every saved recording in `dir`, newest first. Folders without readable captions are skipped.
    static func all(in dir: URL) -> [Recording] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.compactMap(load).sorted { $0.startedAt > $1.startedAt }
    }

    func moveToTrash() throws {
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }

    /// Stores a new name in captions.json, leaving the rest of the file as it was.
    func rename(to newName: String) throws {
        let url = folder.appendingPathComponent("captions.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        json["name"] = newName
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private struct File: Decodable {
        let name: String?  // missing in recordings saved before names existed
        let started_at: String
        let duration: Double
        let lines: [CaptionLine]
    }

    private static func load(_ folder: URL) -> Recording? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("captions.json")),
              let file = try? JSONDecoder().decode(File.self, from: data),
              let startedAt = ISO8601DateFormatter().date(from: file.started_at) else { return nil }
        return Recording(folder: folder, name: file.name ?? folder.lastPathComponent,
                         startedAt: startedAt, duration: file.duration, lines: file.lines)
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let relativeDateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}

/// 9.7 → "0:09", 754 → "12:34", 3725 → "1:02:05".
func formatTime(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
