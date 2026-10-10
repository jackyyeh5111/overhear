// The main window: Start a live session, or open / rename / trash a saved recording.
import AppKit

/// Return opens the selected recording; Delete moves it to the Trash.
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

final class Home: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                  NSTextFieldDelegate {
    var onStart: (() -> Void)?
    var onOpen: ((Recording) -> Void)?

    private let recordingsDir: URL
    private let window: NSWindow
    private let table = RecordingsTable()
    private let emptyLabel = NSTextField(labelWithString: "No recordings yet")
    private var recordings: [Recording] = []

    init(recordingsDir: URL) {
        self.recordingsDir = recordingsDir
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        window.title = "Overhear"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 260)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Home")

        let start = NSButton(title: "Start live captions", target: self, action: #selector(startClicked))
        start.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        start.imagePosition = .imageLeading
        start.bezelStyle = .rounded
        start.controlSize = .large

        let heading = NSTextField(labelWithString: "Recordings")
        heading.font = .boldSystemFont(ofSize: 13)

        for (id, title, width) in [("name", "Name", 280.0), ("date", "Date", 170), ("duration", "Length", 70)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        table.onReturn = { [weak self] in self?.open(row: self?.table.selectedRow ?? -1) }
        table.onDelete = { [weak self] in self?.trash(row: self?.table.selectedRow ?? -1) }
        table.menu = NSMenu()
        table.menu!.addItem(NSMenuItem(title: "Rename", action: #selector(renameClicked), keyEquivalent: ""))
        table.menu!.addItem(.separator())
        table.menu!.addItem(NSMenuItem(title: "Move to Trash", action: #selector(trashClicked), keyEquivalent: ""))
        table.menu!.items.forEach { $0.target = self }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        emptyLabel.textColor = .secondaryLabelColor

        let content = window.contentView!
        for view in [start, heading, scroll, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            start.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            start.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            heading.topAnchor.constraint(equalTo: start.bottomAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    /// Re-reads the recordings folder and brings Home to the front (at launch, and when a
    /// session has ended, so taking focus is expected).
    func show() {
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reload() {
        recordings = Recording.all(in: recordingsDir)
        table.reloadData()
        emptyLabel.isHidden = !recordings.isEmpty
    }

    @objc private func startClicked() {
        window.orderOut(nil)
        onStart?()
    }

    @objc private func openClicked() { open(row: table.clickedRow) }

    @objc private func trashClicked() {
        trash(row: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow)
    }

    /// Turns the row's name into an editable field; Return saves, Esc cancels.
    @objc private func renameClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard recordings.indices.contains(row),
              let field = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTextField else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        field.isEditable = true
        window.makeFirstResponder(field)  // selects the whole name
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)),
              recordings.indices.contains(table.row(for: control)) else { return false }
        control.stringValue = recordings[table.row(for: control)].name
        window.makeFirstResponder(table)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        field.isEditable = false
        let row = table.row(for: field)
        guard recordings.indices.contains(row) else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name != recordings[row].name {
            do {
                try recordings[row].rename(to: name)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
        reload()
        table.selectRowIndexes([row], byExtendingSelection: false)
        window.makeFirstResponder(table)
    }

    private func open(row: Int) {
        guard recordings.indices.contains(row) else { return }
        onOpen?(recordings[row])
    }

    private func trash(row: Int) {
        guard recordings.indices.contains(row) else { return }
        do {
            try recordings[row].moveToTrash()
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
        }
        reload()
        if !recordings.isEmpty {
            table.selectRowIndexes([min(row, recordings.count - 1)], byExtendingSelection: false)
        }
    }

    // Closing Home quits the app (and with it the Python side).
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { recordings.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let id = column?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = id
        cell.lineBreakMode = .byTruncatingTail
        let recording = recordings[row]
        switch id.rawValue {
        case "name":
            cell.stringValue = recording.name
            cell.delegate = self
        case "date":
            cell.stringValue = recording.title
        default:
            cell.stringValue = formatTime(recording.duration)
            cell.alignment = .right
        }
        return cell
    }
}
