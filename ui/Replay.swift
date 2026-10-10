// Replays a saved recording with its captions in lockstep: the line being spoken is highlighted
// and kept in view, and clicking any line plays the audio from there.
import AppKit
import AVFoundation

let leadIn = 0.3            // Deepgram's start can clip the first syllable
let manualScrollPause = 3.0  // seconds auto-scroll waits after the user scrolls

final class Replay: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                    AVAudioPlayerDelegate {
    private let window: NSWindow
    private let table = NSTableView()
    private let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
    private let playButton = NSButton()
    private let slider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "")
    private let font = NSFont.systemFont(ofSize: 14)

    private var lines: [CaptionLine] = []
    private var player: AVAudioPlayer?
    private var current = -1
    private var lastManualScroll = Date.distantPast
    private var timer: Timer?

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
        table.addTableColumn(timeColumn)
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

        let bar = NSStackView(views: [playButton, slider, timeLabel])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = window.contentView!
        for view in [scroll, bar] {
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
        ])

        // Space toggles playback while Replay is the key window.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 49 else { return event }
            self.togglePlay()
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

        let line = lineIndex(at: now)
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
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
            ?? NSTextField(wrappingLabelWithString: "")
        cell.identifier = id
        cell.font = id.rawValue == "time" ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : font
        cell.textColor = id.rawValue == "time" ? .secondaryLabelColor : .labelColor
        cell.stringValue = id.rawValue == "time" ? formatTime(lines[row].start) : lines[row].text
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
