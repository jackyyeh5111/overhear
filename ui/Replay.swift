// Replays a saved recording with its captions in lockstep: the line being spoken is highlighted,
// lines already played are dimmed, and the highlighted line is kept in view. Clicking any line
// plays the audio from there. A mic icon marks the lines the user spoke in. ← / → skip back /
// forward by the step set in the playback bar, and a hint in the corner shows how far. ↑ / ↓
// restart the playing line, then go to the previous / next one. [ / ] change the speed. C covers
// the playing line and Shift+C the whole transcript (press again to uncover). ⌘F finds text in
// the transcript; ⌘C copies the selected lines (⌘-click or ⇧-click to select).
import AppKit
import AVFoundation
import Carbon.HIToolbox  // kVK_ key codes

let leadIn = 0.3            // Deepgram's start can clip the first syllable
let restartGrace = 1.0       // seconds into a line before ↑ / ↓ restart it instead of moving on
let manualScrollPause = 3.0  // seconds auto-scroll waits after the user scrolls
let seekStepKey = "replaySeekStep"
let defaultSeekStep = 3.0    // seconds ← / → skip until the user changes it
let rateKey = "replayRate"
let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]
let findOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

/// A stack view that ignores the mouse, so clicks reach the views underneath.
final class PassThroughStack: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A caption row. The playing line gets an accent-tinted band; selected lines (for copying) a
/// gray one. Text keeps its colors either way, so dimmed and highlighted words stay readable.
final class LineRowView: NSTableRowView {
    var isCurrent = false {
        didSet { if isCurrent != oldValue { needsDisplay = true } }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isCurrent else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        band.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isCurrent else { return }  // the playing line's band already stands out
        NSColor.quaternaryLabelColor.setFill()
        band.fill()
    }

    private var band: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6)
    }
}

/// "1.25×".
func rateTitle(_ rate: Float) -> String { String(format: "%g×", rate) }

final class Replay: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                    NSSearchFieldDelegate, AVAudioPlayerDelegate {
    private let window: NSWindow
    private let table = NSTableView()
    private let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
    private let findField = NSSearchField()
    private let matchLabel = NSTextField(labelWithString: "")
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private let playButton = NSButton()
    private let slider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "")
    private let speed = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stepLabel = NSTextField(labelWithString: "")
    private let stepper = NSStepper()
    private let hintBox = PassThroughStack()
    private let hintIcon = NSImageView()
    private let hintText = NSTextField(labelWithString: "")
    private let font = NSFont.systemFont(ofSize: 14)

    private var heading = ""  // "name — date", atop a copied transcript
    private var lines: [CaptionLine] = []
    private var player: AVAudioPlayer?
    private var rate: Float = {
        let saved = Float(defaults.object(forKey: rateKey) as? Double ?? 1)
        return rates.contains(saved) ? saved : 1
    }()
    private var current = -1
    private var hidden = IndexSet()  // lines whose text is covered
    private var allHidden = false    // what the last Shift+C did, so the next one does the opposite
    private var query = ""           // what the find field searches for
    private var matches: [Int] = []  // lines containing `query`
    private var matchCursor: Int?    // the index in `matches` last jumped to
    private var lastManualScroll = Date.distantPast
    private var timer: Timer?
    private var skipTotal = 0.0     // how far the current run of ← / → presses has moved
    private var hintTimer: Timer?   // ends that run and hides the hint

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 300)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Replay")

        // Find bar: the field, "2 of 7", previous / next; Copy transcript on the right.
        findField.placeholderString = "Find in transcript"
        findField.target = self
        findField.action = #selector(findChanged)
        findField.delegate = self
        matchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        matchLabel.textColor = .secondaryLabelColor
        prevButton = barButton("chevron.up", "Previous match  ⇧↩", #selector(previousMatch))
        nextButton = barButton("chevron.down", "Next match  ↩", #selector(nextMatch))
        let copyButton = NSButton(title: "Copy transcript", target: self, action: #selector(copyTranscript))
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.toolTip = "Copy every line, with its time"
        let findBar = NSStackView(views: [findField, matchLabel, prevButton, nextButton])
        findBar.spacing = 6
        findBar.setCustomSpacing(10, after: findField)

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeColumn.width = 52
        timeColumn.resizingMask = []
        let micColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mic"))
        micColumn.width = 18
        micColumn.resizingMask = []
        table.addTableColumn(timeColumn)
        table.addTableColumn(micColumn)
        table.addTableColumn(textColumn)
        table.headerView = nil
        table.style = .fullWidth
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true  // ⌘-click, ⇧-click, ⌘A: lines for ⌘C
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
        playButton.contentTintColor = .controlAccentColor
        playButton.target = self
        playButton.action = #selector(togglePlay)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        speed.addItems(withTitles: rates.map(rateTitle))
        speed.controlSize = .small
        speed.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speed.target = self
        speed.action = #selector(speedChosen)
        speed.toolTip = "Playback speed  [ ]"
        speed.selectItem(at: rates.firstIndex(of: rate) ?? 1)
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

        let bar = NSStackView(views: [playButton, slider, timeLabel, speed, stepLabel, stepper])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 6, right: 12)
        bar.setCustomSpacing(14, after: timeLabel)
        bar.setCustomSpacing(14, after: speed)
        bar.setCustomSpacing(2, after: stepLabel)
        for label in [timeLabel, stepLabel] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // Lists the keys handled by the monitor below; keep the two in step.
        let keys = NSTextField(wrappingLabelWithString:
            "Space play · ← → skip · ↑ ↓ line · [ ] speed · C cover line · ⇧C cover all · ⌘F find · ⌘C copy")
        keys.font = .systemFont(ofSize: 11)
        keys.textColor = .tertiaryLabelColor
        keys.alignment = .center

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

        let topLine = NSBox()
        topLine.boxType = .separator
        let bottomLine = NSBox()
        bottomLine.boxType = .separator

        let content = window.contentView!
        for view in [findBar, copyButton, topLine, scroll, bottomLine, bar, keys, hintBox] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            findBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            findField.widthAnchor.constraint(equalToConstant: 220),
            copyButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            copyButton.leadingAnchor.constraint(greaterThanOrEqualTo: findBar.trailingAnchor, constant: 12),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            topLine.topAnchor.constraint(equalTo: findBar.bottomAnchor, constant: 8),
            topLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: bottomLine.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            keys.topAnchor.constraint(equalTo: bar.bottomAnchor),
            keys.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            keys.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            keys.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            hintBox.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),  // clear of the scroller
            hintBox.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -8),
        ])
        updateMatches()

        // Keep in step with the hint line under the bar:
        // while Replay is the key window, Space toggles playback, ← / → skip (held, they repeat),
        // ↑ / ↓ restart the playing line or go to the previous / next one, [ / ] change the speed,
        // C covers the playing line and Shift+C the whole transcript. Not while typing in the
        // find field, where these keys edit the text.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  !(self.window.firstResponder is NSTextView) else { return event }
            let plain = event.modifierFlags.isDisjoint(with: [.command, .option, .control])
            switch Int(event.keyCode) {
            case kVK_Space: self.togglePlay()
            case kVK_LeftArrow: self.seek(by: -self.stepper.doubleValue)
            case kVK_RightArrow: self.seek(by: self.stepper.doubleValue)
            case kVK_UpArrow: self.jumpLine(by: -1)
            case kVK_DownArrow: self.jumpLine(by: 1)
            case kVK_ANSI_LeftBracket where plain: self.stepRate(by: -1)
            case kVK_ANSI_RightBracket where plain: self.stepRate(by: 1)
            case kVK_ANSI_C where plain && !event.isARepeat:
                if event.modifierFlags.contains(.shift) { self.toggleAllHidden() } else { self.toggleCurrentHidden() }
            default: return event
            }
            return nil
        }
    }

    private func barButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                         target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        return b
    }

    /// Shows `recording` (reusing the window), ready to play from the start.
    func open(_ recording: Recording) {
        stop()
        lines = recording.lines
        heading = "\(recording.name) — \(recording.title)"
        player = try? AVAudioPlayer(contentsOf: recording.audioURL)
        player?.delegate = self
        player?.enableRate = true  // must be set before prepareToPlay
        player?.rate = rate
        player?.prepareToPlay()
        window.title = recording.name
        window.subtitle = recording.title
        current = -1
        hidden = []
        allHidden = false
        findField.stringValue = ""
        query = ""
        table.deselectAll(nil)
        table.reloadData()
        table.scrollRowToVisible(0)
        updateMatches()
        slider.maxValue = player?.duration ?? recording.duration
        slider.doubleValue = 0
        [playButton, slider, speed].forEach { $0.isEnabled = player != nil }
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
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

    /// A plain click plays from the line; ⌘-click and ⇧-click only select, for copying.
    @objc private func lineClicked() {
        guard let player, lines.indices.contains(table.clickedRow),
              NSApp.currentEvent?.modifierFlags.isDisjoint(with: [.command, .shift]) ?? true else { return }
        table.deselectAll(nil)  // the playing line's band shows where it is
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
        var target = current
        if current < 0 || (player?.currentTime ?? 0) - entry(current) <= restartGrace { target += offset }
        guard target < lines.count else { return }
        go(to: target)
    }

    /// Moves playback to the start of `line` (the very start if it's -1), without changing
    /// play/pause, and brings it into view.
    private func go(to line: Int) {
        guard let player else { return }
        player.currentTime = line >= 0 ? entry(line) : 0
        lastManualScroll = .distantPast
        tick()
    }

    private func entry(_ line: Int) -> Double { max(0, lines[line].start - leadIn) }

    @objc private func speedChosen() { setRate(rates[speed.indexOfSelectedItem]) }

    /// `[` / `]`: the next slower / faster speed, shown in the corner pill.
    private func stepRate(by offset: Int) {
        let i = (rates.firstIndex(of: rate) ?? 1) + offset
        guard rates.indices.contains(i), player != nil else { return }
        setRate(rates[i])
        hideHint()  // ends any skip run, so the pill shows only this
        flashHint(rateTitle(rate), symbol: "speedometer")
    }

    private func setRate(_ newRate: Float) {
        rate = newRate
        defaults.set(Double(rate), forKey: rateKey)
        player?.rate = rate
        speed.selectItem(at: rates.firstIndex(of: rate) ?? 1)
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
        let symbol = player?.isPlaying == true ? "pause.circle.fill" : "play.circle.fill"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Play/Pause")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .regular))
        slider.doubleValue = now
        timeLabel.stringValue = player == nil
            ? "Audio file missing" : "\(formatTime(now)) / \(formatTime(duration))"

        // A line counts as playing from its lead-in, so jumping to it lights it at once.
        let line = lineIndex(at: now + leadIn)
        if line != current {
            let old = current
            current = line
            for (row, on) in [(old, false), (line, true)] where row >= 0 {
                (table.rowView(atRow: row, makeIfNecessary: false) as? LineRowView)?.isCurrent = on
            }
            // The lines in between switch between played (dimmed) and not.
            refreshText(IndexSet(integersIn: max(0, min(old, line))...max(old, line)))
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

    // MARK: Find

    /// ⌘F.
    @objc func startFind(_ sender: Any?) { window.makeFirstResponder(findField) }

    @objc private func findChanged() {
        query = findField.stringValue.trimmingCharacters(in: .whitespaces)
        updateMatches()
        refreshText(IndexSet(integersIn: lines.indices))
    }

    private func updateMatches() {
        matches = query.isEmpty ? [] : lines.indices.filter { lines[$0].text.range(of: query, options: findOptions) != nil }
        matchCursor = nil
        showMatchCount()
    }

    /// "3 matches" until the first jump, then "2 of 3".
    private func showMatchCount() {
        if query.isEmpty {
            matchLabel.stringValue = ""
        } else if matches.isEmpty {
            matchLabel.stringValue = "No matches"
        } else if let matchCursor {
            matchLabel.stringValue = "\(matchCursor + 1) of \(matches.count)"
        } else {
            matchLabel.stringValue = matches.count == 1 ? "1 match" : "\(matches.count) matches"
        }
        prevButton.isEnabled = !matches.isEmpty
        nextButton.isEnabled = !matches.isEmpty
    }

    @objc private func nextMatch() { jumpToMatch(forward: true) }
    @objc private func previousMatch() { jumpToMatch(forward: false) }

    /// Goes to the next / previous line containing the search, wrapping around. The first jump
    /// counts from the playing line, which itself is next if it matches.
    private func jumpToMatch(forward: Bool) {
        guard !matches.isEmpty else { return }
        let from = matchCursor.map { matches[$0] }
        let next = forward
            ? matches.firstIndex { $0 > (from ?? current - 1) } ?? 0
            : matches.lastIndex { $0 < (from ?? current + 1) } ?? matches.count - 1
        matchCursor = next
        showMatchCount()
        go(to: matches[next])
    }

    /// In the find field: Return / Shift+Return go to the next / previous match; Esc clears the
    /// search and hands the keys back to playback.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            jumpToMatch(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        case #selector(NSResponder.cancelOperation(_:)):
            findField.stringValue = ""
            findChanged()
            window.makeFirstResponder(table)
        default:
            return false
        }
        return true
    }

    // MARK: Copy

    /// ⌘C: the selected lines, or the playing one when none are selected.
    @objc func copy(_ sender: Any?) {
        let rows = table.selectedRowIndexes.isEmpty && current >= 0
            ? IndexSet(integer: current) : table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        put(rows.map(transcriptLine), count: rows.count)
    }

    @objc private func copyTranscript() {
        guard !lines.isEmpty else { return }
        put([heading, ""] + lines.indices.map(transcriptLine), count: lines.count)
    }

    /// "[1:23] text".
    private func transcriptLine(_ row: Int) -> String { "[\(formatTime(lines[row].start))] \(lines[row].text)" }

    private func put(_ text: [String], count: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.joined(separator: "\n"), forType: .string)
        hideHint()
        flashHint(count == 1 ? "Copied 1 line" : "Copied \(count) lines", symbol: "checkmark")
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = LineRowView()
        view.isCurrent = row == current
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let id = column?.identifier else { return nil }
        if id.rawValue == "mic" {
            guard lines[row].mic == true else { return nil }
            let icon = tableView.makeView(withIdentifier: id, owner: self) as? NSImageView
                ?? NSImageView(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "You spoke")!)
            icon.identifier = id
            icon.contentTintColor = .systemOrange
            icon.toolTip = "Your microphone heard speech in this line"
            return icon
        }
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
            ?? NSTextField(wrappingLabelWithString: "")
        cell.identifier = id
        if id == textColumn.identifier {
            cell.attributedStringValue = styledText(row)
        } else {
            let alignRight = NSMutableParagraphStyle()
            alignRight.alignment = .right
            cell.attributedStringValue = NSAttributedString(string: formatTime(lines[row].start), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: alignRight,
                .baselineOffset: font.ascender - NSFont.systemFont(ofSize: 12).ascender,  // level with the text
            ])
        }
        return cell
    }

    /// A line's text as shown: covered, or dimmed once played, with every match of the search
    /// highlighted.
    private func styledText(_ row: Int) -> NSAttributedString {
        let text = lines[row].text
        if hidden.contains(row) {
            // Same text, drawn invisible on a gray background: a bar the size of the line.
            return NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.clear, .backgroundColor: NSColor.tertiaryLabelColor])
        }
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: row < current ? NSColor.secondaryLabelColor : NSColor.labelColor])
        var rest = text.startIndex..<text.endIndex
        while !query.isEmpty, let found = text.range(of: query, options: findOptions, range: rest) {
            out.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black],
                              range: NSRange(found, in: text))
            rest = found.upperBound..<text.endIndex
        }
        return out
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
