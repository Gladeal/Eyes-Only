import AppKit
import Carbon.HIToolbox

/// A key combination, saved as the key's code plus modifiers; `key` is what the key is called, for showing it.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt   // NSEvent.ModifierFlags: command, option, control, shift only
    var key: String

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// As macOS writes shortcuts: ⌃⌥⇧⌘ then the key.
    var display: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") +
        (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
    }

    var carbonModifiers: UInt32 {
        (flags.contains(.command) ? UInt32(cmdKey) : 0) | (flags.contains(.option) ? UInt32(optionKey) : 0) |
        (flags.contains(.control) ? UInt32(controlKey) : 0) | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }

    static let functionKeys: [UInt16: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17", 79: "F18", 80: "F19", 90: "F20"]
    static let namedKeys: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"]

    init(keyCode: UInt32, modifiers: UInt, key: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.key = key }

    init(_ event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
        key = Self.functionKeys[event.keyCode] ?? Self.namedKeys[event.keyCode]
            ?? (event.characters(byApplyingModifiers: [])?.uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(event.keyCode)"
    }
}

/// System-wide shortcuts through macOS's hot-key service — works in every app, no extra permission needed.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    /// Names of shortcuts that couldn't be registered: another app (or macOS) already has that combination.
    private(set) var failed: Set<String> = []

    func set(_ items: [(name: String, shortcut: Shortcut, action: () -> Void)]) {
        removeAll()
        installHandler()
        for (i, item) in items.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4559_4F4E), id: UInt32(i + 1))   // 'EYON'
            if RegisterEventHotKey(item.shortcut.keyCode, item.shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref); actions[id.id] = item.action
            } else {
                failed.insert(item.name)
            }
        }
    }

    func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []; actions = [:]; failed = []
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.actions[number]?() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
