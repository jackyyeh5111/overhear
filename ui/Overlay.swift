// Floating transcript overlay for a live session: a transparent, always-on-top panel that never
// takes focus and stays visible over full-screen apps. A pill in the corner shows the session is
// live and for how long. Toggles turn the mic and system audio on and off; Save and Discard end
// the session.
import AppKit

let historyLimit = 50
let defaultFontSize: CGFloat = 22
let fontSizes: ClosedRange<CGFloat> = 12...48
// How dark the tint over the blurred background is.
let opacitySteps: [CGFloat] = [0.15, 0.35, 0.55, 0.8]
let cornerRadius: CGFloat = 14
let defaultSize = NSSize(width: 640, height: 200)
// Toolbar look of each input toggle, keyed by the name Python knows it by.
let inputLooks: [(name: String, on: String, off: String, label: String, shortcut: String?)] = [
    ("mic", "mic", "mic.slash", "microphone", "⌥⇧M"),
    ("system", "speaker.wave.2", "speaker.slash", "system audio", nil),
]
let minSize = NSSize(width: 280, height: 100)  // room for the REC pill and two lines

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The frosted background. Ignores the mouse, so clicks reach RootView and move or resize.
final class GlassView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

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
    /// Shown under the toolbar on hover. Not a toolTip: those only appear in the active app, and
    /// the overlay never makes us active.
    var hint = ""

    /// A soft square behind the button while the pointer is on it.
    var isHovered = false {
        didSet { layer?.backgroundColor = isHovered ? NSColor.white.withAlphaComponent(0.15).cgColor : nil }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Overlay: NSObject, NSWindowDelegate {
    let panel: OverlayPanel
    private let root = RootView()
    private let glass = GlassView()
    private let tint = NSView()  // darkens the glass by `opacity`
    private let scroll = NSScrollView()
    // TextKit 1: TextKit 2 only estimates the height of off-screen text, so when old lines drop
    // off the top the view lands short of the bottom and auto-scroll stops following.
    private let text = DragTextView(usingTextLayoutManager: false)
    private let toolbar = NSStackView()
    private let hint = NSTextField(labelWithString: "")
    private let hintBox = NSStackView()  // pads `hint` and gives it a background
    // A pill under the captions for "press again to confirm" and "Saving…".
    private let banner = NSStackView()
    private let bannerIcon = NSImageView()
    private let bannerSpinner = NSProgressIndicator()
    private let bannerText = NSTextField(labelWithString: "")
    // Always on during a session: a red dot (gray while every input is off), the elapsed time,
    // and a slashed icon for each input that's off.
    private let pill = PassThroughStack()
    private let dot = NSView()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private var offIcons: [String: NSImageView] = [:]
    private var startedAt = Date()
    private var endedAt: Date?  // when Save or Discard was sent; the clock stops there
    private var toolbarShown = false
    private var hovered: ToolButton?
    private var inputButtons: [String: ToolButton] = [:]
    private var lockButton: ToolButton!
    private var saveButton: ToolButton!
    private var discardButton: ToolButton!

    private var finals: [(text: String, isError: Bool)] = []
    private var draft = ""
    private var status = ""
    private var armed: ToolButton?  // Save or Discard, waiting for its confirming second click / press
    private var armTimer: Timer?
    private var flashTimer: Timer?  // hides a short-lived banner, e.g. "Microphone off"
    private var shownError = false
    private var locked = false
    // Remembered between runs; the first run captures system audio only.
    private(set) var inputs: [String: Bool] = [
        "system": defaults.object(forKey: "input.system") as? Bool ?? true,
        "mic": defaults.bool(forKey: "input.mic"),
    ]
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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.minSize = minSize
        panel.acceptsMouseMovedEvents = true  // feeds RootView's resize cursors
        panel.delegate = self
        panel.contentView = root

        root.wantsLayer = true
        root.layer?.cornerRadius = cornerRadius
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // The blur comes from the window server, which ignores layer clipping; the mask rounds it.
        glass.frame = root.bounds
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active  // the app is never active, which would otherwise turn the blur off
        glass.maskImage = Overlay.roundedMask()
        tint.frame = glass.bounds
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        glass.addSubview(tint)
        root.addSubview(glass)

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

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        elapsed.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        elapsed.textColor = NSColor.white.withAlphaComponent(0.85)
        pill.addArrangedSubview(dot)
        pill.addArrangedSubview(elapsed)
        for look in inputLooks {
            let icon = NSImageView(image: NSImage(systemSymbolName: look.off,
                                                  accessibilityDescription: "\(look.label) off")!)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            icon.contentTintColor = NSColor.white.withAlphaComponent(0.6)
            offIcons[look.name] = icon
            pill.addArrangedSubview(icon)
        }
        pill.spacing = 5
        pill.edgeInsets = NSEdgeInsets(top: 3, left: 7, bottom: 3, right: 8)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        pill.layer?.cornerRadius = 9
        pill.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pill)

        for look in inputLooks {
            let b = button(look.on, look.label, #selector(toggleInput))
            b.identifier = NSUserInterfaceItemIdentifier(look.name)
            inputButtons[look.name] = b
            toolbar.addArrangedSubview(b)
            showInput(look.name)
        }
        toolbar.setCustomSpacing(12, after: toolbar.arrangedSubviews.last!)
        lockButton = button("lock.open", "Lock (click-through)", #selector(toggleLock))
        saveButton = button("square.and.arrow.down", "Save recording  ⌥⇧S", #selector(save))
        discardButton = button("trash", "Discard recording  ⌥⇧D", #selector(discard))
        for view in [
            button("textformat.size.smaller", "Smaller text", #selector(smaller)),
            button("textformat.size.larger", "Larger text", #selector(larger)),
            button("circle.lefthalf.filled", "Background opacity", #selector(cycleOpacity)),
            button("eraser", "Clear screen", #selector(clear)),
            lockButton!,
            saveButton!,
            discardButton!,
        ] { toolbar.addArrangedSubview(view) }
        toolbar.setCustomSpacing(12, after: lockButton)
        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        toolbar.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        toolbar.layer?.cornerRadius = 8
        toolbar.alphaValue = 0  // fades in while the pointer is over the overlay
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)

        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .white
        hintBox.addArrangedSubview(hint)
        hintBox.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        hintBox.wantsLayer = true
        hintBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hintBox.layer?.cornerRadius = 5
        hintBox.isHidden = true
        hintBox.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hintBox)

        bannerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        bannerSpinner.style = .spinning
        bannerSpinner.controlSize = .small
        bannerText.font = .systemFont(ofSize: 12, weight: .medium)
        bannerText.textColor = .white
        for view in [bannerIcon, bannerSpinner, bannerText] { banner.addArrangedSubview(view) }
        banner.spacing = 6
        banner.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 12)
        banner.appearance = NSAppearance(named: .darkAqua)  // a white spinner
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        banner.layer?.cornerRadius = 12
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        banner.isHidden = true
        banner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            banner.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            banner.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -16),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            hintBox.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            hintBox.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            pill.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            pill.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])

        applyOpacity()
        layoutCaptions()

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

    /// A rounded rectangle that stretches to any size, keeping its corners.
    private static func roundedMask() -> NSImage {
        let side = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                       bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    private func symbol(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))!
    }

    private func button(_ name: String, _ label: String, _ action: Selector) -> ToolButton {
        let b = ToolButton(image: symbol(name, label), target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.hint = label
        b.wantsLayer = true
        b.layer?.cornerRadius = 5
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 26),
            b.heightAnchor.constraint(equalToConstant: 22),
        ])
        return b
    }

    // MARK: Session

    /// Shows an empty overlay for a new session, without taking focus from the app in front.
    func begin() {
        finals.removeAll()
        draft = ""
        status = ""
        shownError = false
        saveButton.isEnabled = true
        discardButton.isEnabled = true
        startedAt = Date()
        endedAt = nil
        disarm()
        render()
        updatePill()
        updateDot()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    // Both take two clicks or presses in a row, since one stray click or keypress could end an
    // hour-long session or throw it away. They also run from ⌥⇧S / ⌥⇧D, which stay live until
    // Python answers "ended"; the disabled buttons say the choice has already been sent.
    @objc func save() {
        confirm(saveButton, color: .systemGreen, prompt: "Press ⌥⇧S or click Save again to save") {
            self.end("save", progress: "Saving…")
        }
    }

    @objc func discard() {
        confirm(discardButton, color: .systemRed, prompt: "Press ⌥⇧D or click Discard again to discard") {
            self.end("discard", progress: "Discarding…")
        }
    }

    /// The first call arms `button` for 3 seconds; a second call within that time runs `action`.
    private func confirm(_ button: ToolButton, color: NSColor, prompt: String, action: () -> Void) {
        guard button.isEnabled else { return }
        guard armed === button else {
            disarm()
            armed = button
            button.contentTintColor = color
            showBanner(prompt, icon: button.image, color: color)
            armTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.disarm() }
            return
        }
        action()
    }

    private func disarm() {
        armTimer?.invalidate()
        armTimer = nil
        armed?.contentTintColor = .white
        armed = nil
        hideBanner()
    }

    /// Tells Python the user's choice; it answers "ended" once the recording is handled.
    private func end(_ choice: String, progress: String) {
        disarm()
        saveButton.isEnabled = false
        discardButton.isEnabled = false
        endedAt = Date()
        updateDot()
        showBanner(progress)
        emit(choice)
    }

    /// Shows `message` in the banner after `icon`, or after a spinner when there is no icon.
    private func showBanner(_ message: String, icon: NSImage? = nil, color: NSColor = .white) {
        flashTimer?.invalidate()  // whatever shows now stays until it's done
        flashTimer = nil
        bannerText.stringValue = message
        bannerIcon.image = icon
        bannerIcon.contentTintColor = color
        bannerIcon.isHidden = icon == nil
        bannerSpinner.isHidden = icon != nil
        if icon == nil { bannerSpinner.startAnimation(nil) } else { bannerSpinner.stopAnimation(nil) }
        setBannerHidden(false)
    }

    /// Shows `message` for 1.5 seconds, unless a confirm prompt or "Saving…" is showing.
    private func flashBanner(_ message: String, icon: NSImage?) {
        guard armed == nil, saveButton.isEnabled else { return }
        showBanner(message, icon: icon)
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.hideBanner()
        }
    }

    private func hideBanner() {
        flashTimer?.invalidate()
        flashTimer = nil
        bannerSpinner.stopAnimation(nil)
        setBannerHidden(true)
    }

    private func setBannerHidden(_ hidden: Bool) {
        banner.isHidden = hidden
        layoutCaptions()
    }

    /// Fits the captions below the REC pill and above the banner while it shows, so neither
    /// covers a line, and keeps the newest line in view if it was.
    private func layoutCaptions() {
        let followed = atBottom
        var frame = root.bounds.insetBy(dx: 12, dy: 10)
        frame.size.height -= pill.fittingSize.height + 2
        if !banner.isHidden {
            let lift = banner.fittingSize.height + 4
            frame.origin.y += lift
            frame.size.height -= lift
        }
        scroll.frame = frame
        if followed { text.scrollToEndOfDocument(nil) }
    }

    // MARK: REC pill

    private func updatePill() {
        let time = formatTime((endedAt ?? Date()).timeIntervalSince(startedAt))
        if elapsed.stringValue != time { elapsed.stringValue = time }
    }

    /// Red and pulsing while recording something; gray and still while every input is off or
    /// once the session is ending.
    private func updateDot() {
        let live = inputs.values.contains(true) && endedAt == nil
        dot.layer?.backgroundColor = (live ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.4)).cgColor
        guard live && !reduceMotion else {
            dot.layer?.removeAnimation(forKey: "pulse")
            return
        }
        guard dot.layer?.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(pulse, forKey: "pulse")
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
        case "input":
            if let on = message.on { setInput(message.text, on: on) }
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
        let followed = atBottom

        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = fontSize * 0.3
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let out = NSMutableAttributedString()
        func add(_ line: String, _ color: NSColor, font: NSFont = font) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .shadow: shadow,
            ]
            out.append(NSAttributedString(string: (out.length > 0 ? "\n" : "") + line, attributes: attrs))
        }
        // The newest line is brightest, so the eye lands on it; in-progress text is fainter still.
        for (i, line) in finals.enumerated() {
            add(line.text, line.isError ? NSColor(red: 1, green: 0.45, blue: 0.45, alpha: 1)
                : NSColor.white.withAlphaComponent(i == finals.count - 1 ? 1 : 0.75))
        }
        if !draft.isEmpty { add(draft, NSColor.white.withAlphaComponent(0.55)) }
        if out.length == 0 && !status.isEmpty {
            add(status, NSColor.white.withAlphaComponent(0.5),
                font: .systemFont(ofSize: max(fontSizes.lowerBound, fontSize * 0.7), weight: .medium))
        }

        text.textStorage?.setAttributedString(out)
        if followed { text.scrollRangeToVisible(NSRange(location: out.length, length: 0)) }
    }

    /// Whether the newest line is in view, so new text should keep it there.
    private var atBottom: Bool { scroll.contentView.bounds.maxY >= text.frame.height - 4 }

    private func applyOpacity() {
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(opacity).cgColor
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

    @objc private func toggleInput(_ sender: ToolButton) {
        guard let name = sender.identifier?.rawValue else { return }
        toggle(name)
    }

    /// ⌥⇧M. The toolbar is likely hidden (the pointer is in another app), so the banner says
    /// what happened. Ignored once Save or Discard has been sent, like those shortcuts.
    func toggleMic() {
        guard saveButton.isEnabled else { return }
        toggle("mic")
        let on = inputs["mic"] ?? false
        flashBanner(on ? "Microphone on" : "Microphone off", icon: inputButtons["mic"]?.image)
    }

    private func toggle(_ name: String) {
        let on = !(inputs[name] ?? false)
        setInput(name, on: on)
        emit("input", ["name": name, "on": on])
    }

    /// Sets an input without telling Python: for its failure reports, and for Home's toggles
    /// before a session (Python hears those with "start").
    func setInput(_ name: String, on: Bool) {
        guard inputButtons[name] != nil else { return }
        inputs[name] = on
        defaults.set(on, forKey: "input.\(name)")
        showInput(name)
    }

    /// Slashed and dimmed while off, in the toolbar and the REC pill; the hint says what a click does.
    private func showInput(_ name: String) {
        guard let b = inputButtons[name], let look = inputLooks.first(where: { $0.name == name }) else { return }
        let on = inputs[name] ?? false
        b.image = symbol(on ? look.on : look.off, look.label)
        b.contentTintColor = on ? .white : NSColor.white.withAlphaComponent(0.45)
        b.hint = "Turn \(look.label) \(on ? "off" : "on")" + (look.shortcut.map { "  \($0)" } ?? "")
        offIcons[name]?.isHidden = on
        updateDot()
    }

    @objc private func toggleLock() {
        locked.toggle()
        lockButton.image = symbol(locked ? "lock" : "lock.open", "Lock")
        lockButton.hint = locked ? "Unlock" : "Lock (click-through)"
        for view in toolbar.arrangedSubviews where view !== lockButton { view.isHidden = locked }
        if !locked { panel.ignoresMouseEvents = false }
    }

    private func pollPointer() {
        let pointer = NSEvent.mouseLocation
        let inside = panel.frame.contains(pointer)
        if inside != toolbarShown {
            toolbarShown = inside
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.15
                toolbar.animator().alphaValue = inside ? 1 : 0
            }
        }
        let hovered = inside ? toolbar.arrangedSubviews.first {
            !$0.isHidden && screenFrame(of: $0).contains(pointer)
        } as? ToolButton : nil
        if hovered !== self.hovered {
            self.hovered?.isHovered = false
            hovered?.isHovered = true
            self.hovered = hovered
        }
        hint.stringValue = hovered?.hint ?? ""
        hintBox.isHidden = hovered == nil
        if panel.isVisible { updatePill() }
        if locked {
            // Click-through everywhere except the lock button, so it can still unlock.
            panel.ignoresMouseEvents = !screenFrame(of: lockButton).insetBy(dx: -6, dy: -6).contains(pointer)
        }
    }

    private func screenFrame(of view: NSView) -> NSRect {
        panel.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// Python is gone (stdin closed): quit, leaving any error on screen long enough to read.
    func finish() {
        DispatchQueue.main.asyncAfter(deadline: .now() + (shownError ? 3 : 0)) { exit(0) }
    }

    // MARK: NSWindowDelegate — save on every change, since Ctrl+C kills us without warning.

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) {
        panel.invalidateShadow()  // it follows the window's rounded outline
        saveFrame()
    }

    private func saveFrame() {
        defaults.set(NSStringFromRect(panel.frame), forKey: "frame")
    }
}
