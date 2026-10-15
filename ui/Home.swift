// The main window: start a live session, or find, open, rename and trash saved recordings.
import AppKit

/// Return opens the selected recording; Delete moves every selected one to the Trash.
final class RecordingsTable: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()   // Return, keypad Enter
        case 51, 117: onDelete?()  // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }
}

/// One recording in the list: its name and length, when it was made (with a mic badge if the
/// user spoke), and its first caption.
final class RecordingCell: NSTableCellView {
    let nameField = NSTextField(labelWithString: "")
    private let lengthField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let micBadge = NSImageView(image: NSImage(systemSymbolName: "mic.fill",
                                                      accessibilityDescription: "You spoke")!)
    private let previewField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lengthField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        lengthField.textColor = .secondaryLabelColor
        lengthField.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateField.font = .systemFont(ofSize: 11)
        dateField.textColor = .secondaryLabelColor
        micBadge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        micBadge.contentTintColor = .systemOrange
        micBadge.toolTip = "You spoke in this recording"
        previewField.font = .systemFont(ofSize: 12)
        previewField.textColor = .secondaryLabelColor
        previewField.lineBreakMode = .byTruncatingTail
        previewField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = nameField

        for view in [nameField, lengthField, dateField, micBadge, previewField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: lengthField.leadingAnchor, constant: -8),
            lengthField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            lengthField.firstBaselineAnchor.constraint(equalTo: nameField.firstBaselineAnchor),
            dateField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 1),
            dateField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            micBadge.leadingAnchor.constraint(equalTo: dateField.trailingAnchor, constant: 5),
            micBadge.centerYAnchor.constraint(equalTo: dateField.centerYAnchor),
            previewField.topAnchor.constraint(equalTo: dateField.bottomAnchor, constant: 3),
            previewField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            previewField.trailingAnchor.constraint(equalTo: lengthField.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ recording: Recording) {
        nameField.stringValue = recording.name
        lengthField.stringValue = formatTime(recording.duration)
        dateField.stringValue = recording.relativeTitle
        micBadge.isHidden = !recording.hasMic
        previewField.stringValue = recording.preview.map { "“\($0)”" } ?? "No captions"
    }

    // Light text on a selected row, for every label rather than just `textField`.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            for field in [nameField, lengthField, dateField, previewField] { field.cell?.backgroundStyle = backgroundStyle }
        }
    }
}

/// A shortcut drawn as a key cap, e.g. ⌥⇧R.
final class KeyCap: NSView {
    init(_ keys: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: keys)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Drawn rather than layer-backed, so the colors follow light / dark mode.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}

final class Home: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                  NSTextFieldDelegate {
    var onStart: (() -> Void)?
    var onOpen: ((Recording) -> Void)?
    /// The overlay's input toggles, which these checkboxes set before a session.
    var inputs: () -> [String: Bool] = { [:] }
    var onInputChange: ((String, Bool) -> Void)?

    private let recordingsDir: URL
    private let window: NSWindow
    private let table = RecordingsTable()
    private let search = NSSearchField()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private let emptyState = NSStackView()
    private var trashButton: NSButton!
    private var inputToggles: [String: NSButton] = [:]
    private var recordings: [Recording] = []
    private var shown: [Recording] = []  // `recordings` that match the search; the table's rows
    private var foldersBeforeSession: Set<URL>?  // set while a session runs, to spot what it saved

    init(recordingsDir: URL) {
        self.recordingsDir = recordingsDir
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        window.title = "Overhear"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 380)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Home")

        let start = NSButton(title: "Start live captions", target: self, action: #selector(startClicked))
        start.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        start.imagePosition = .imageLeading
        start.bezelStyle = .rounded
        start.bezelColor = .controlAccentColor
        start.controlSize = .large
        start.font = .systemFont(ofSize: 14, weight: .semibold)

        let shortcut = NSStackView(views: [label("or press"), KeyCap("⌥⇧R"), label("in any app")])
        shortcut.spacing = 5

        let captionRow = NSStackView(views: [label("Caption")])
        captionRow.spacing = 12
        for (name, title) in [("system", "System audio"), ("mic", "Microphone")] {
            let toggle = NSButton(checkboxWithTitle: title, target: self, action: #selector(inputToggled))
            toggle.identifier = NSUserInterfaceItemIdentifier(name)
            toggle.toolTip = "Caption this input; you can also switch it from the overlay during a session"
            inputToggles[name] = toggle
            captionRow.addArrangedSubview(toggle)
        }

        let hero = NSStackView(views: [start, shortcut, captionRow])
        hero.orientation = .vertical
        hero.alignment = .centerX
        hero.spacing = 8
        hero.setCustomSpacing(14, after: shortcut)

        let heading = NSTextField(labelWithString: "Recordings")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        search.placeholderString = "Search names and transcripts"
        search.target = self
        search.action = #selector(searchChanged)

        trashButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Move to Trash")!,
                               target: self, action: #selector(trashSelected))
        trashButton.isBordered = false
        trashButton.toolTip = "Move selected recordings to the Trash"
        trashButton.isEnabled = false

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recording")))
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 62
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true  // ⌘-click, ⇧-click, ⌘A
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        table.onReturn = { [weak self] in self?.open(row: self?.table.selectedRow ?? -1) }
        table.onDelete = { [weak self] in self?.trashSelected() }
        table.menu = NSMenu()
        table.menu!.addItem(NSMenuItem(title: "Rename", action: #selector(renameClicked), keyEquivalent: ""))
        table.menu!.addItem(.separator())
        table.menu!.addItem(NSMenuItem(title: "Move to Trash", action: #selector(trashClicked), keyEquivalent: ""))
        table.menu!.items.forEach { $0.target = self }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyTitle.textColor = .secondaryLabelColor
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        emptyDetail.preferredMaxLayoutWidth = 300
        for view in [emptyIcon, emptyTitle, emptyDetail] { emptyState.addArrangedSubview(view) }
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 6

        let content = window.contentView!
        for view in [hero, heading, search, trashButton!, scroll, emptyState] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            hero.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            heading.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 26),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            search.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            search.leadingAnchor.constraint(greaterThanOrEqualTo: heading.trailingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -10),
            search.widthAnchor.constraint(equalToConstant: 230),
            trashButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            trashButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            // The inset table style pads its rows, so the list sits closer to the edges.
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -20),
        ])
        window.initialFirstResponder = table  // not the search field, which would show a focus ring
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// Re-reads the recordings folder and brings Home to the front (at launch, and when a
    /// session has ended, so taking focus is expected). After a session, selects what it saved.
    func show() {
        for (name, toggle) in inputToggles { toggle.state = inputs()[name] == true ? .on : .off }
        reload()
        if let before = foldersBeforeSession {
            foldersBeforeSession = nil
            let saved = Set(recordings.map(\.folder)).subtracting(before)  // empty after Discard
            if !saved.isEmpty {
                search.stringValue = ""
                refilter(select: saved)
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-reads the recordings folder, keeping the same ones selected.
    private func reload() {
        let selected = selectedFolders
        recordings = Recording.all(in: recordingsDir)
        refilter(select: selected)
    }

    /// Shows the recordings matching the search and selects those in `folders`.
    private func refilter(select folders: Set<URL>) {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = recordings.filter { $0.matches(query) }
        table.reloadData()
        let rows = IndexSet(shown.indices.filter { folders.contains(shown[$0].folder) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) }
        trashButton.isEnabled = !rows.isEmpty

        emptyState.isHidden = !shown.isEmpty
        if recordings.isEmpty {
            emptyIcon.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: nil)
            emptyTitle.stringValue = "No recordings yet"
            emptyDetail.stringValue = "Start live captions, then press Save to keep the session here."
        } else {
            emptyIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            emptyTitle.stringValue = "No matches"
            emptyDetail.stringValue = "No recording is named or says “\(query)”."
        }
    }

    private var selectedFolders: Set<URL> {
        Set(table.selectedRowIndexes.filter(shown.indices.contains).map { shown[$0].folder })
    }

    @objc private func searchChanged() { refilter(select: selectedFolders) }

    /// ⌘F.
    @objc func startFind(_ sender: Any?) { window.makeFirstResponder(search) }

    @objc private func inputToggled(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onInputChange?(name, sender.state == .on)
    }

    @objc private func startClicked() { start() }

    /// Hides Home and starts a session (the button, or ⌥⇧R from any app).
    func start() {
        window.makeFirstResponder(table)  // ends a rename in progress, keeping what was typed
        foldersBeforeSession = Set(recordings.map(\.folder))
        window.orderOut(nil)
        onStart?()
    }

    @objc private func openClicked() { open(row: table.clickedRow) }

    @objc private func trashSelected() { trash(rows: table.selectedRowIndexes) }

    /// Like Finder: right-clicking inside the selection trashes all of it, outside just that row.
    @objc private func trashClicked() {
        let row = table.clickedRow
        trash(rows: row < 0 || table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : [row])
    }

    /// Turns the row's name into an editable field; Return saves, Esc cancels.
    @objc private func renameClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard shown.indices.contains(row),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? RecordingCell else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        cell.nameField.isEditable = true
        window.makeFirstResponder(cell.nameField)  // selects the whole name
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)),
              shown.indices.contains(table.row(for: control)) else { return false }
        control.stringValue = shown[table.row(for: control)].name
        window.makeFirstResponder(table)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== search else { return }
        field.isEditable = false
        let row = table.row(for: field)
        guard shown.indices.contains(row) else { return }
        let recording = shown[row]
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name != recording.name {
            do {
                try recording.rename(to: name)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
        recordings = Recording.all(in: recordingsDir)
        refilter(select: [recording.folder])
        window.makeFirstResponder(table)
    }

    private func open(row: Int) {
        guard shown.indices.contains(row) else { return }
        onOpen?(shown[row])
    }

    /// Trashes as many of `rows` as it can, then reports the first failure, if any.
    private func trash(rows: IndexSet) {
        let doomed = rows.filter(shown.indices.contains)
        guard let first = doomed.first else { return }
        var failure: Error?
        for row in doomed {
            do {
                try shown[row].moveToTrash()
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { NSAlert(error: failure).beginSheetModal(for: window) }
        recordings = Recording.all(in: recordingsDir)
        refilter(select: [])
        // Like Finder, select the row that took the first one's place.
        if !shown.isEmpty {
            table.selectRowIndexes([min(first, shown.count - 1)], byExtendingSelection: false)
        }
    }

    // Closing Home quits the app (and with it the Python side).
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        trashButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let id = column?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? RecordingCell ?? RecordingCell()
        cell.identifier = id
        cell.nameField.delegate = self
        cell.show(shown[row])
        return cell
    }
}
