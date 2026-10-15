// overhear-ui: the Overhear app. A Home window starts live sessions and lists saved recordings,
// a floating overlay shows live captions, and Replay plays a recording back with its captions.
// Launched by stream_system_audio.py, which does the capturing, transcribing and saving:
//
//   overhear-ui <recordings_dir> <youtube_dir>
//
//   stdin  (from Python): {"type": "status" | "interim" | "final" | "error" | "ended", "text": "..."}
//                         {"type": "input", "text": "mic", "on": false}   (an input failed)
//                         {"type": "import" | "import_error", "text": "..."}   (a YouTube import)
//                         {"type": "imported", "text": "Added “Title”", "folder": "<path>"}
//   stdout (to Python):   {"type": "start", "system": true, "mic": false}
//                         {"type": "input", "name": "mic", "on": true}    (a toggle was clicked)
//                         {"type": "save" | "discard"}
//                         {"type": "import", "url": "https://youtu.be/..."}
//
// Quits when stdin closes. Python reads our exit (stdout EOF) as "the user quit".
import AppKit
import Carbon.HIToolbox  // kVK_ key codes

let defaults = UserDefaults(suiteName: "com.jackyyeh.deepgram-overlay")!
let recordingsDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                        ? CommandLine.arguments[1] : "recordings")
let youtubeDir = URL(fileURLWithPath: CommandLine.arguments.count > 2
                     ? CommandLine.arguments[2] : "youtube")

struct Message: Decodable {
    let type: String
    let text: String
    let on: Bool?  // "input" only
    let folder: String?  // "imported" only
}

/// Tells Python what the user did, e.g. emit("input", ["name": "mic", "on": true]).
func emit(_ type: String, _ fields: [String: Any] = [:]) {
    guard let data = try? JSONSerialization.data(withJSONObject: fields.merging(["type": type]) { $1 }) else { return }
    try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
}

/// Lets NSCursor.set() take effect while the app is inactive, which it is whenever the overlay
/// is in use. Uses a private WindowServer property, looked up at runtime so a missing symbol only
/// costs the resize cursors.
func allowCursorInBackground() {
    typealias DefaultConnection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    guard let defaultSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection"),
          let setSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty") else {
        FileHandle.standardError.write("overhear-ui: resize cursors unavailable\n".data(using: .utf8)!)
        return
    }
    let connection = unsafeBitCast(defaultSym, to: DefaultConnection.self)()
    let status = unsafeBitCast(setSym, to: SetProperty.self)(
        connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    if status != 0 {
        FileHandle.standardError.write("overhear-ui: resize cursors unavailable (\(status))\n".data(using: .utf8)!)
    }
}

func mainMenu() -> NSMenu {
    let menu = NSMenu()
    for (title, items) in [
        ("Overhear", [NSMenuItem(title: "Quit Overhear", action: #selector(NSApplication.terminate(_:)),
                                 keyEquivalent: "q")]),
        ("File", [NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)),
                             keyEquivalent: "w")]),
        ("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"),
            .separator(),
            // Home and Replay each answer startFind: by focusing their search field.
            NSMenuItem(title: "Find…", action: Selector(("startFind:")), keyEquivalent: "f"),
        ]),
    ] {
        let item = NSMenuItem()
        item.submenu = NSMenu(title: title)
        items.forEach(item.submenu!.addItem)
        menu.addItem(item)
    }
    return menu
}

signal(SIGPIPE, SIG_IGN)  // if Python dies, emit() fails quietly and stdin EOF quits us

let app = NSApplication.shared
app.setActivationPolicy(.regular)  // Home and Replay are ordinary windows; the overlay never takes focus
app.mainMenu = mainMenu()
allowCursorInBackground()

let overlay = Overlay()
let replay = Replay()
let home = Home(recordingsDir: recordingsDir, youtubeDir: youtubeDir)

// ⌥⇧R starts a session; ⌥⇧M toggles the mic during it; ⌥⇧S and ⌥⇧D end it. Each is live only
// when it can do something.
let startKey = HotKey(kVK_ANSI_R) { home.start() }
let sessionKeys = [
    HotKey(kVK_ANSI_M) { overlay.toggleMic() },
    HotKey(kVK_ANSI_S) { overlay.save() },
    HotKey(kVK_ANSI_D) { overlay.discard() },
]
func setLive(_ live: Bool) {
    startKey.isEnabled = !live
    sessionKeys.forEach { $0.isEnabled = live }
}

home.onStart = {
    replay.close()  // its audio would be captured and captioned too
    setLive(true)
    emit("start", overlay.inputs)
    overlay.begin()
}
home.onOpen = { replay.open($0) }
home.onImport = { emit("import", ["url": $0]) }
// Home's input toggles and the overlay's are the same setting.
home.inputs = { overlay.inputs }
home.onInputChange = { overlay.setInput($0, on: $1) }
home.show()
setLive(false)

Thread {
    let decoder = JSONDecoder()
    while let line = readLine() {
        guard let message = try? decoder.decode(Message.self, from: Data(line.utf8)) else { continue }
        DispatchQueue.main.async {
            if message.type == "ended" {
                setLive(false)
                overlay.hide()
                home.show()
            } else if message.type.hasPrefix("import") {
                home.importUpdate(message)
            } else {
                overlay.apply(message)
            }
        }
    }
    DispatchQueue.main.async { overlay.finish() }
}.start()

// Set once launching has finished; set earlier, it's reset to the generic executable icon.
DispatchQueue.main.async { app.applicationIconImage = overhearIcon() }
app.run()
