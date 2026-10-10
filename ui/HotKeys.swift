// System-wide ⌥⇧ shortcuts, so a session can be started and ended without leaving the app in
// front. Carbon hot keys need no Accessibility permission, unlike a global NSEvent monitor.
import Carbon.HIToolbox

/// One ⌥⇧<key> shortcut. It only takes the key combo from other apps while enabled, so ⌥⇧S still
/// types in other apps when there is no session to save.
final class HotKey {
    private static var all: [UInt32: HotKey] = [:]
    private static var handlerInstalled = false

    private let id: UInt32
    private let keyCode: Int
    private let action: () -> Void
    private var ref: EventHotKeyRef?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                RegisterEventHotKey(UInt32(keyCode), UInt32(optionKey | shiftKey),
                                    EventHotKeyID(signature: OSType(0x4F564852), id: id),  // "OVHR"
                                    GetApplicationEventTarget(), 0, &ref)
            } else if let ref {
                UnregisterEventHotKey(ref)
                self.ref = nil
            }
        }
    }

    /// `keyCode` is a virtual key code, e.g. kVK_ANSI_R.
    init(_ keyCode: Int, action: @escaping () -> Void) {
        id = UInt32(HotKey.all.count + 1)
        self.keyCode = keyCode
        self.action = action
        HotKey.all[id] = self
        HotKey.installHandler()
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.all[hotKeyID.id]?.action()
            return noErr
        }, 1, &pressed, nil, nil)
    }
}
