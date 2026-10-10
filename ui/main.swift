// overhear-ui: the Overhear app. A Home window starts live sessions and lists saved recordings,
// a floating overlay shows live captions, and Replay plays a recording back with its captions.
// Launched by stream_system_audio.py, which does the capturing, transcribing and saving:
//
//   overhear-ui <recordings_dir>
//
//   stdin  (from Python): {"type": "status" | "interim" | "final" | "error" | "ended", "text": "..."}
//   stdout (to Python):   {"type": "start" | "save" | "discard"}
//
// Quits when stdin closes. Python reads our exit (stdout EOF) as "the user quit".
import AppKit

let defaults = UserDefaults(suiteName: "com.jackyyeh.deepgram-overlay")!
let recordingsDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                        ? CommandLine.arguments[1] : "recordings")

struct Message: Decodable {
    let type: String
    let text: String
}

/// Tells Python which button the user clicked, e.g. {"type":"save"}.
func emit(_ type: String) {
    try? FileHandle.standardOutput.write(contentsOf: Data("{\"type\":\"\(type)\"}\n".utf8))
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
let home = Home(recordingsDir: recordingsDir)
home.onStart = {
    replay.close()  // its audio would be captured and captioned too
    emit("start")
    overlay.begin()
}
home.onOpen = { replay.open($0) }
home.show()

Thread {
    let decoder = JSONDecoder()
    while let line = readLine() {
        guard let message = try? decoder.decode(Message.self, from: Data(line.utf8)) else { continue }
        DispatchQueue.main.async {
            if message.type == "ended" {
                overlay.hide()
                home.show()
            } else {
                overlay.apply(message)
            }
        }
    }
    DispatchQueue.main.async { overlay.finish() }
}.start()

app.run()
