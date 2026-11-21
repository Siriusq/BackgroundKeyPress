import AppKit

struct RunningApp: Identifiable, Hashable {
    let pid: pid_t
    let name: String
    var id: pid_t { pid }
    var label: String { "\(name) (PID \(pid))" }
}

struct Hotkey: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var name: String

    static func load(from defaults: UserDefaults = .standard, key: String, fallback: Hotkey) -> Hotkey {
        let prefix = "hotkey.\(key)."
        guard let keyCodeValue = defaults.object(forKey: prefix + "keyCode") as? NSNumber,
              let modifierValue = defaults.object(forKey: prefix + "modifiers") as? NSNumber else { return fallback }
        let keyCode = UInt16(truncatingIfNeeded: keyCodeValue.intValue)
        let storedModifiers = modifierValue.intValue
        var modifiers: NSEvent.ModifierFlags = []
        if storedModifiers & 1 != 0 { modifiers.insert(.command) }
        if storedModifiers & 2 != 0 { modifiers.insert(.option) }
        if storedModifiers & 4 != 0 { modifiers.insert(.control) }
        if storedModifiers & 8 != 0 { modifiers.insert(.shift) }
        // Read values written by the previous version, which stored NSEvent's raw flags.
        if modifiers.isEmpty, storedModifiers > 15 {
            let legacy = NSEvent.ModifierFlags(rawValue: UInt(storedModifiers))
            if legacy.contains(.command) { modifiers.insert(.command) }
            if legacy.contains(.option) { modifiers.insert(.option) }
            if legacy.contains(.control) { modifiers.insert(.control) }
            if legacy.contains(.shift) { modifiers.insert(.shift) }
        }
        guard !modifiers.isEmpty else { return fallback }
        return Hotkey(keyCode: keyCode, modifiers: modifiers,
                      name: defaults.string(forKey: prefix + "name") ?? "Key \(keyCode)")
    }

    func save(to defaults: UserDefaults = .standard, key: String) {
        let prefix = "hotkey.\(key)."
        var storedModifiers = 0
        if modifiers.contains(.command) { storedModifiers |= 1 }
        if modifiers.contains(.option) { storedModifiers |= 2 }
        if modifiers.contains(.control) { storedModifiers |= 4 }
        if modifiers.contains(.shift) { storedModifiers |= 8 }
        defaults.set(Int(keyCode), forKey: prefix + "keyCode")
        defaults.set(storedModifiers, forKey: prefix + "modifiers")
        defaults.set(name, forKey: prefix + "name")
    }
}

enum KeyNameFormatter {
    static func hotkeyName(_ event: NSEvent) -> String {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + (event.charactersIgnoringModifiers?.uppercased() ?? "Key\(event.keyCode)")
    }

    static func keyName(_ event: NSEvent) -> String {
        let specialKeys: [UInt16: String] = [
            0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete", 0x35: "Esc",
            0x72: "Insert", 0x73: "Home", 0x74: "Page Up", 0x75: "Forward Delete",
            0x77: "End", 0x79: "Page Down", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
            0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12"
        ]
        if let name = specialKeys[event.keyCode] { return name }
        if let character = event.charactersIgnoringModifiers, !character.isEmpty {
            return character.uppercased()
        }
        return "Key \(event.keyCode)"
    }
}
