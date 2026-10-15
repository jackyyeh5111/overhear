// Replays a saved recording with its captions in lockstep: the line being spoken is highlighted
// and kept in view, and clicking any line plays the audio from there. A mic icon marks the lines
// the user spoke in. ← / → skip back / forward by the step set in the playback bar, and a hint in
// the corner shows how far. ↑ / ↓ restart the playing line, then go to the previous / next one.
// C covers the playing line and Shift+C the whole transcript (press again
// to uncover).
import AppKit
import AVFoundation
import Carbon.HIToolbox  // kVK_ key codes

let leadIn = 0.3            // Deepgram's start can clip the first syllable
let restartGrace = 1.0       // seconds into a line before ↑ / ↓ restart it instead of moving on
let manualScrollPause = 3.0  // seconds auto-scroll waits after the user scrolls
let seekStepKey = "replaySeekStep"
let defaultSeekStep = 3.0    // seconds ← / → skip until the user changes it

/// A stack view that ignores the mouse, so clicks reach the captions underneath.
final class PassThroughStack: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class Replay: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                    AVAudioPlayerDelegate {
    private let window: NSWindow
    private let table = NSTableView()
    private let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
    private let playButton = NSButton()
    private let slider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let stepper = NSStepper()
    private let hintBox = PassThroughStack()
    private let hintIcon = NSImageView()
    private let hintText = NSTextField(labelWithString: "")
    private let font = NSFont.systemFont(ofSize: 14)

    private var lines: [CaptionLine] = []
    private var player: AVAudioPlayer?
    private var current = -1
    private var hidden = IndexSet()  // lines whose text is covered
    private var allHidden = false    // what the last Shift+C did, so the next one does the opposite
    private var lastManualScroll = Date.distantPast
    private var timer: Timer?
    private var skipTotal = 0.0     // how far the current run of ← / → presses has moved
    private var hintTimer: Timer?   // ends that run and hides the hint

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 240)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Replay")

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeColumn.width = 64
        timeColumn.resizingMask = []
        let micColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mic"))
        micColumn.width = 18
        micColumn.resizingMask = []
        table.addTableColumn(timeColumn)
        table.addTableColumn(micColumn)
        table.addTableColumn(textColumn)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(lineClicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main
        ) { [weak self] _ in self?.lastManualScroll = Date() }
        // Wrapped lines change height when the window is resized.
        NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification, object: table, queue: .main
        ) { [weak self] _ in self?.relayoutRows() }

        playButton.bezelStyle = .regularSquare
        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(togglePlay)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        stepLabel.font = timeLabel.font
        stepLabel.textColor = .secondaryLabelColor
        stepper.minValue = 1
        stepper.maxValue = 60
        stepper.increment = 1
        stepper.autorepeat = true
        stepper.valueWraps = false
        stepper.doubleValue = defaults.object(forKey: seekStepKey) as? Double ?? defaultSeekStep
        stepper.target = self
        stepper.action = #selector(stepChanged)
        for view in [stepLabel, stepper] as [NSView] { view.toolTip = "Seconds ← and → skip" }
        showStep()

        let bar = NSStackView(views: [playButton, slider, timeLabel, stepLabel, stepper])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.setCustomSpacing(2, after: stepLabel)
        for label in [timeLabel, stepLabel] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // Same look as the overlay's banner.
        hintIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        hintIcon.contentTintColor = .white
        hintText.font = .systemFont(ofSize: 12, weight: .medium)
        hintText.textColor = .white
        for view in [hintIcon, hintText] { hintBox.addArrangedSubview(view) }
        hintBox.spacing = 6
        hintBox.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 12)
        hintBox.wantsLayer = true
        hintBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        hintBox.layer?.cornerRadius = 12
        hintBox.layer?.borderWidth = 1
        hintBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        hintBox.isHidden = true

        let content = window.contentView!
        for view in [scroll, bar, hintBox] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hintBox.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),  // clear of the scroller
            hintBox.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -8),
        ])

        // While Replay is the key window, Space toggles playback, ← / → skip (held, they repeat),
        // ↑ / ↓ restart the playing line or go to the previous / next one, C covers the playing
        // line and Shift+C the whole transcript.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch Int(event.keyCode) {
            case kVK_Space: self.togglePlay()
            case kVK_LeftArrow: self.seek(by: -self.stepper.doubleValue)
            case kVK_RightArrow: self.seek(by: self.stepper.doubleValue)
            case kVK_UpArrow: self.jumpLine(by: -1)
            case kVK_DownArrow: self.jumpLine(by: 1)
            case kVK_ANSI_C where event.modifierFlags.isDisjoint(with: [.command, .option, .control])
                                  && !event.isARepeat:
                if event.modifierFlags.contains(.shift) { self.toggleAllHidden() } else { self.toggleCurrentHidden() }
            default: return event
            }
            return nil
        }
    }

    /// Shows `recording` (reusing the window), ready to play from the start.
    func open(_ recording: Recording) {
        stop()
        lines = recording.lines
        player = try? AVAudioPlayer(contentsOf: recording.audioURL)
        player?.delegate = self
        player?.prepareToPlay()
        window.title = "\(recording.name) — \(recording.title)"
        current = -1
        hidden = []
        allHidden = false
        table.reloadData()
        table.scrollRowToVisible(0)
        slider.maxValue = player?.duration ?? recording.duration
        slider.doubleValue = 0
        [playButton, slider].forEach { $0.isEnabled = player != nil }
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) { stop() }

    private func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        hideHint()
    }

    // MARK: Playback

    @objc private func togglePlay() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
        tick()
    }

    @objc private func lineClicked() {
        guard let player, lines.indices.contains(table.clickedRow) else { return }
        player.currentTime = max(0, lines[table.clickedRow].start - leadIn)
        player.play()
        lastManualScroll = .distantPast
        tick()
    }

    @objc private func sliderMoved() {
        player?.currentTime = slider.doubleValue
        lastManualScroll = .distantPast
        tick()
    }

    /// Skips `delta` seconds without changing play/pause; past the end, finishes playback there.
    private func seek(by delta: Double) {
        guard let player else { return }
        let before = player.currentTime
        let target = before + delta
        if target >= player.duration { player.pause() }
        player.currentTime = min(max(0, target), player.duration)
        lastManualScroll = .distantPast  // bring the highlighted line back into view
        tick()
        showSkipHint(moved: player.currentTime - before, forward: delta > 0)
    }

    /// Restarts the highlighted line, or, within its first `restartGrace` seconds, moves `offset`
    /// lines from it, without changing play/pause. Above the first line is the very start; below
    /// the last there's nowhere to go.
    private func jumpLine(by offset: Int) {
        guard let player else { return }
        func entry(_ i: Int) -> Double { max(0, lines[i].start - leadIn) }
        var target = current
        if current < 0 || player.currentTime - entry(current) <= restartGrace { target += offset }
        guard target < lines.count else { return }
        player.currentTime = target >= 0 ? entry(target) : 0
        lastManualScroll = .distantPast  // bring the highlighted line back into view
        tick()
    }

    /// Flashes how far the current run of ← / → presses has moved, e.g. "⟲ 9s", for 1.5 s.
    private func showSkipHint(moved: Double, forward: Bool) {
        skipTotal += moved
        let shown = Int(skipTotal.rounded())
        let back = shown < 0 || (shown == 0 && !forward)  // a net-zero run points the way of the last press
        flashHint("\(abs(shown))s", symbol: back ? "gobackward" : "goforward")
    }

    /// Shows `text` after the `symbol` icon in the corner pill for 1.5 s.
    private func flashHint(_ text: String, symbol: String) {
        hintIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        hintText.stringValue = text
        hintBox.isHidden = false
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.hideHint()
        }
    }

    private func hideHint() {
        hintTimer?.invalidate()
        hintTimer = nil
        hintBox.isHidden = true
        skipTotal = 0
    }

    /// Covers the playing line's text, or uncovers it.
    private func toggleCurrentHidden() {
        guard current >= 0 else { return }
        if hidden.contains(current) { hidden.remove(current) } else { hidden.insert(current) }
        refreshText(IndexSet(integer: current))
    }

    /// Covers every line, or uncovers every line, alternating with each press.
    private func toggleAllHidden() {
        allHidden.toggle()
        hidden = allHidden ? IndexSet(integersIn: lines.indices) : []
        refreshText(IndexSet(integersIn: lines.indices))
        hideHint()  // ends any skip run, so the pill shows only this
        flashHint(allHidden ? "Transcript hidden" : "Transcript shown",
                  symbol: allHidden ? "eye.slash" : "eye")
    }

    private func refreshText(_ rows: IndexSet) {
        table.reloadData(forRowIndexes: rows,
                         columnIndexes: IndexSet(integer: table.column(withIdentifier: textColumn.identifier)))
    }

    @objc private func stepChanged() {
        defaults.set(stepper.doubleValue, forKey: seekStepKey)
        showStep()
    }

    private func showStep() { stepLabel.stringValue = "±\(Int(stepper.doubleValue))s" }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { tick() }

    /// Moves the highlight, slider and clock to where the audio is.
    private func tick() {
        let now = player?.currentTime ?? 0
        let duration = player?.duration ?? 0
        let symbol = player?.isPlaying == true ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Play/Pause")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        slider.doubleValue = now
        timeLabel.stringValue = player == nil
            ? "Audio file missing" : "\(formatTime(now)) / \(formatTime(duration))"

        // A line counts as playing from its lead-in, so jumping to it lights it at once.
        let line = lineIndex(at: now + leadIn)
        if line != current {
            current = line
            if line >= 0 {
                table.selectRowIndexes([line], byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }
        if current >= 0 && Date().timeIntervalSince(lastManualScroll) > manualScrollPause {
            table.scrollRowToVisible(current)
        }
    }

    /// The line being spoken at `time`: the last one that started at or before it, so a pause
    /// between lines keeps the previous one lit. -1 before the first line starts.
    /// E.g. starts [0.5, 4.0, 9.2] at time 6.0 → 1.
    private func lineIndex(at time: Double) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let id = column?.identifier else { return nil }
        if id.rawValue == "mic" {
            guard lines[row].mic == true else { return nil }
            let icon = tableView.makeView(withIdentifier: id, owner: self) as? NSImageView
                ?? NSImageView(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "You spoke")!)
            icon.identifier = id
            icon.contentTintColor = .systemOrange  // stays visible on the highlighted row
            icon.toolTip = "Your microphone heard speech in this line"
            return icon
        }
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
            ?? NSTextField(wrappingLabelWithString: "")
        cell.identifier = id
        cell.font = id.rawValue == "time" ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : font
        cell.textColor = id.rawValue == "time" ? .secondaryLabelColor : .labelColor
        cell.stringValue = id.rawValue == "time" ? formatTime(lines[row].start) : lines[row].text
        if id == textColumn.identifier && hidden.contains(row) {
            // Same text, drawn invisible on a gray background: a bar the size of the line.
            cell.attributedStringValue = NSAttributedString(string: lines[row].text, attributes: [
                .font: font, .foregroundColor: NSColor.clear, .backgroundColor: NSColor.tertiaryLabelColor])
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let bounds = (lines[row].text as NSString).boundingRect(
            with: NSSize(width: textColumn.width - 6, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return max(22, ceil(bounds.height) + 8)
    }

    private func relayoutRows() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<lines.count))
        }
    }
}
