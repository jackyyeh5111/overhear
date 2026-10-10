// Floating transcript overlay: a transparent, always-on-top panel that never takes focus and
// stays visible over full-screen apps. Reads JSON lines from stdin and quits on EOF:
//
//   {"type": "status" | "interim" | "final" | "error", "text": "..."}
//
// Usage: overlay   (launched by stream_system_audio.py)
import AppKit

let defaults = UserDefaults(suiteName: "com.jackyyeh.deepgram-overlay")!
let historyLimit = 50
let defaultFontSize: CGFloat = 22
let fontSizes: ClosedRange<CGFloat> = 12...48
let opacitySteps: [CGFloat] = [0.35, 0.55, 0.75, 0.9]
let defaultSize = NSSize(width: 640, height: 200)
let minSize = NSSize(width: 280, height: 80)

struct Message: Decodable {
    let type: String
    let text: String
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct Edges: OptionSet {
    let rawValue: Int
    static let left = Edges(rawValue: 1 << 0)
    static let right = Edges(rawValue: 1 << 1)
    static let top = Edges(rawValue: 1 << 2)
    static let bottom = Edges(rawValue: 1 << 3)
}

// The panel never becomes key, so every click is a "first" click; accept them all.
// Dragging the border resizes and shows a resize cursor; dragging anywhere else moves.
final class RootView: NSView {
    private let edgeWidth: CGFloat = 6
    private let cornerSize: CGFloat = 16

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The app is never active, so cursor rects don't apply; track the pointer ourselves.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) { cursor(for: edges(at: event)).set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        let grabbed = edges(at: event)
        if grabbed.isEmpty { window?.performDrag(with: event) } else { resize(grabbed) }
    }

    private func edges(at event: NSEvent) -> Edges {
        let p = convert(event.locationInWindow, from: nil)
        guard p.x < edgeWidth || p.x > bounds.width - edgeWidth
                || p.y < edgeWidth || p.y > bounds.height - edgeWidth else { return [] }
        // Within the border band, the ends of each edge count as corners.
        var edges: Edges = []
        if p.x < cornerSize { edges.insert(.left) } else if p.x > bounds.width - cornerSize { edges.insert(.right) }
        if p.y < cornerSize { edges.insert(.bottom) } else if p.y > bounds.height - cornerSize { edges.insert(.top) }
        return edges
    }

    private func cursor(for edges: Edges) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch edges {
        case [.top, .left]: position = .topLeft
        case [.top, .right]: position = .topRight
        case [.bottom, .left]: position = .bottomLeft
        case [.bottom, .right]: position = .bottomRight
        case .left: position = .left
        case .right: position = .right
        case .top: position = .top
        case .bottom: position = .bottom
        default: return .arrow
        }
        return .frameResize(position: position, directions: .all)
    }

    private func resize(_ edges: Edges) {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        let startFrame = window.frame
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
              event.type == .leftMouseDragged {
            let dx = NSEvent.mouseLocation.x - start.x
            let dy = NSEvent.mouseLocation.y - start.y
            var frame = startFrame
            if edges.contains(.left) {
                frame.size.width = max(window.minSize.width, startFrame.width - dx)
                frame.origin.x = startFrame.maxX - frame.width
            } else if edges.contains(.right) {
                frame.size.width = max(window.minSize.width, startFrame.width + dx)
            }
            if edges.contains(.bottom) {
                frame.size.height = max(window.minSize.height, startFrame.height - dy)
                frame.origin.y = startFrame.maxY - frame.height
            } else if edges.contains(.top) {
                frame.size.height = max(window.minSize.height, startFrame.height + dy)
            }
            window.setFrame(frame, display: true)
            cursor(for: edges).set()
        }
    }
}

final class DragTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

final class ToolButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Overlay: NSObject, NSWindowDelegate {
    let panel: OverlayPanel
    private let root = RootView()
    private let scroll = NSScrollView()
    private let text = DragTextView()
    private let toolbar = NSStackView()
    private var lockButton: NSButton!

    private var finals: [(text: String, isError: Bool)] = []
    private var draft = ""
    private var status = ""
    private var shownError = false
    private var locked = false
    private var fontSize = CGFloat(defaults.object(forKey: "fontSize") as? Double ?? Double(defaultFontSize))
    private var opacity = CGFloat(defaults.object(forKey: "opacity") as? Double ?? Double(opacitySteps[1]))

    override init() {
        panel = OverlayPanel(contentRect: Overlay.initialFrame(),
                             styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        // Full-screen video is composited above ordinary floating windows.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.minSize = minSize
        panel.acceptsMouseMovedEvents = true  // feeds RootView's resize cursors
        panel.delegate = self
        panel.contentView = root

        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true

        scroll.frame = root.bounds.insetBy(dx: 12, dy: 10)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        root.addSubview(scroll)

        text.frame = NSRect(origin: .zero, size: scroll.contentSize)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = false
        scroll.documentView = text

        lockButton = button("lock.open", "Lock (click-through)", #selector(toggleLock))
        for view in [
            button("textformat.size.smaller", "Smaller text", #selector(smaller)),
            button("textformat.size.larger", "Larger text", #selector(larger)),
            button("circle.lefthalf.filled", "Background opacity", #selector(cycleOpacity)),
            button("trash", "Clear", #selector(clear)),
            lockButton!,
            button("xmark", "Close", #selector(close)),
        ] { toolbar.addArrangedSubview(view) }
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        toolbar.layer?.cornerRadius = 6
        toolbar.isHidden = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
        ])

        applyOpacity()
        render()

        // Tracking areas don't fire while the panel ignores mouse events, so poll the pointer.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollPointer() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func initialFrame() -> NSRect {
        if let saved = defaults.string(forKey: "frame") {
            let frame = NSRectFromString(saved)
            if frame.width >= minSize.width, frame.height >= minSize.height,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                return frame
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: screen.midX - defaultSize.width / 2, y: screen.minY + 80,
                      width: defaultSize.width, height: defaultSize.height)
    }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))!
        let b = ToolButton(image: image, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = label
        return b
    }

    // MARK: Content

    func apply(_ message: Message) {
        switch message.type {
        case "status":
            status = message.text
        case "interim":
            draft = message.text
        case "final":
            draft = ""
            append(message.text, isError: false)
        case "error":
            shownError = true
            append(message.text, isError: true)
        default:
            return
        }
        render()
    }

    private func append(_ line: String, isError: Bool) {
        finals.append((line, isError))
        if finals.count > historyLimit { finals.removeFirst(finals.count - historyLimit) }
    }

    private func render() {
        let atBottom = scroll.contentView.bounds.maxY >= text.frame.height - 4

        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = fontSize * 0.3
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let out = NSMutableAttributedString()
        func add(_ line: String, _ color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .shadow: shadow,
            ]
            out.append(NSAttributedString(string: (out.length > 0 ? "\n" : "") + line, attributes: attrs))
        }
        for line in finals {
            add(line.text, line.isError ? NSColor(red: 1, green: 0.45, blue: 0.45, alpha: 1) : .white)
        }
        if !draft.isEmpty { add(draft, NSColor.white.withAlphaComponent(0.6)) }
        if out.length == 0 && !status.isEmpty { add(status, NSColor.white.withAlphaComponent(0.45)) }

        text.textStorage?.setAttributedString(out)
        if atBottom { text.scrollRangeToVisible(NSRange(location: out.length, length: 0)) }
    }

    private func applyOpacity() {
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(opacity).cgColor
    }

    // MARK: Controls

    @objc private func smaller() { setFontSize(fontSize - 2) }
    @objc private func larger() { setFontSize(fontSize + 2) }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, fontSizes.lowerBound), fontSizes.upperBound)
        defaults.set(Double(fontSize), forKey: "fontSize")
        render()
    }

    @objc private func cycleOpacity() {
        opacity = opacitySteps.first(where: { $0 > opacity + 0.01 }) ?? opacitySteps[0]
        defaults.set(Double(opacity), forKey: "opacity")
        applyOpacity()
    }

    @objc private func clear() {
        finals.removeAll()
        draft = ""
        shownError = false
        render()
    }

    @objc private func toggleLock() {
        locked.toggle()
        lockButton.image = NSImage(systemSymbolName: locked ? "lock" : "lock.open",
                                   accessibilityDescription: "Lock")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        for view in toolbar.arrangedSubviews where view !== lockButton { view.isHidden = locked }
        if !locked { panel.ignoresMouseEvents = false }
    }

    @objc private func close() { exit(0) }

    private func pollPointer() {
        let pointer = NSEvent.mouseLocation
        toolbar.isHidden = !panel.frame.contains(pointer)
        if locked {
            // Click-through everywhere except the lock button, so it can still unlock.
            let lockFrame = panel.convertToScreen(lockButton.convert(lockButton.bounds, to: nil))
            panel.ignoresMouseEvents = !lockFrame.insetBy(dx: -6, dy: -6).contains(pointer)
        }
    }

    /// stdin closed: quit, leaving any error on screen long enough to read.
    func finish() {
        DispatchQueue.main.asyncAfter(deadline: .now() + (shownError ? 3 : 0)) { exit(0) }
    }

    // MARK: NSWindowDelegate — save on every change, since Ctrl+C kills us without warning.

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        defaults.set(NSStringFromRect(panel.frame), forKey: "frame")
    }
}

/// Lets NSCursor.set() take effect while the app is inactive, which this overlay always is.
/// Uses a private WindowServer property, looked up at runtime so a missing symbol only
/// costs the resize cursors.
func allowCursorInBackground() {
    typealias DefaultConnection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    guard let defaultSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection"),
          let setSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty") else {
        FileHandle.standardError.write("overlay: resize cursors unavailable\n".data(using: .utf8)!)
        return
    }
    let connection = unsafeBitCast(defaultSym, to: DefaultConnection.self)()
    let status = unsafeBitCast(setSym, to: SetProperty.self)(
        connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    if status != 0 {
        FileHandle.standardError.write("overlay: resize cursors unavailable (\(status))\n".data(using: .utf8)!)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon or menu bar
allowCursorInBackground()

let overlay = Overlay()
overlay.panel.orderFrontRegardless()  // show without activating, so focus stays where it was

Thread {
    let decoder = JSONDecoder()
    while let line = readLine() {
        guard let message = try? decoder.decode(Message.self, from: Data(line.utf8)) else { continue }
        DispatchQueue.main.async { overlay.apply(message) }
    }
    DispatchQueue.main.async { overlay.finish() }
}.start()

app.run()
