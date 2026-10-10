import AppKit

/// Modifier choices for quick paste (modifier + 1…9) and plain-text mode.
enum ShortcutModifier: String, Codable, CaseIterable {
    case command, option, control, shift
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }
    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }
    var title: String {
        switch self {
        case .command: return "⌘ Command"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .shift: return "⇧ Shift"
        }
    }
    static let quickPasteChoices: [ShortcutModifier] = [.command, .option, .control]
    static let plainTextChoices: [ShortcutModifier] = [.shift, .option, .control]
}

/// A shelf-local shortcut (only active while the shelf is key), such as next/previous board.
struct ShelfChord: Codable, Equatable {
    static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    var keyCode: UInt16
    var modifiers: UInt
    var keyName: String

    static let nextBoard = ShelfChord(keyCode: 124, modifiers: NSEvent.ModifierFlags.command.rawValue, keyName: "→")
    static let previousBoard = ShelfChord(keyCode: 123, modifiers: NSEvent.ModifierFlags.command.rawValue, keyName: "←")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.mask) }
    var label: String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyName
    }
    /// Keys the shelf already uses for something else, or that cannot be recorded.
    static let reservedKeyCodes: Set<UInt16> = [36, 76, 48, 49, 51, 53, 117, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    /// ⌘+letter combinations with a fixed meaning on the shelf.
    static let reservedCommandKeys: Set<String> = ["a", "c", "e", "f", "n", "o", "q", "r", "t", "v", "w", "z", ","]
    var valid: Bool {
        guard modifiers == flags.rawValue, !keyName.isEmpty, !flags.isDisjoint(with: [.command, .option, .control]) else { return false }
        if Self.reservedKeyCodes.contains(keyCode) { return false }
        if flags == .command, Self.reservedCommandKeys.contains(keyName.lowercased()) || Int(keyName).map({ (1...9).contains($0) }) == true { return false }
        return true
    }
    static func from(_ event: NSEvent) -> ShelfChord {
        let specials: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down"]
        let name = specials[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "键\(event.keyCode)"
        return ShelfChord(keyCode: event.keyCode, modifiers: event.modifierFlags.intersection(mask).rawValue, keyName: name)
    }
    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection(Self.mask) == flags
    }
    /// Arrow, Home and End chords would break cursor movement inside the search field.
    var movesTextCursor: Bool { [123, 124, 125, 126, 115, 119].contains(keyCode) }
}

enum ShelfChordTarget: String { case nextBoard, previousBoard }

struct ShelfShortcuts: Codable, Equatable {
    var nextBoard = ShelfChord.nextBoard
    var previousBoard = ShelfChord.previousBoard
    var quickPaste = ShortcutModifier.command
    var plainText = ShortcutModifier.shift

    static let standard = ShelfShortcuts()
    private static let key = "shelfShortcuts"

    var quickPasteLabel: String { quickPaste.symbol + "1–9" }
    /// Modifier flags that quick-paste the nth card; adding the plain-text modifier pastes it as plain text.
    func quickPasteMatch(_ flags: NSEvent.ModifierFlags) -> (matches: Bool, plain: Bool) {
        let active = flags.intersection(ShelfChord.mask)
        if active == quickPaste.flag { return (true, false) }
        if active == quickPaste.flag.union(plainText.flag) { return (true, true) }
        return (false, false)
    }
    func isPlain(_ flags: NSEvent.ModifierFlags) -> Bool { flags.contains(plainText.flag) }

    /// Quick paste and plain-text mode must use different modifiers.
    func settingQuickPaste(_ value: ShortcutModifier) -> ShelfShortcuts {
        var copy = self; copy.quickPaste = value
        if copy.plainText == value { copy.plainText = ShortcutModifier.plainTextChoices.first { $0 != value } ?? .shift }
        return copy
    }
    func settingPlainText(_ value: ShortcutModifier) -> ShelfShortcuts {
        var copy = self; copy.plainText = value
        if copy.quickPaste == value { copy.quickPaste = ShortcutModifier.quickPasteChoices.first { $0 != value } ?? .command }
        return copy
    }
    var isConsistent: Bool {
        quickPaste != plainText && nextBoard.valid && previousBoard.valid && nextBoard != previousBoard
            && ShortcutModifier.quickPasteChoices.contains(quickPaste) && ShortcutModifier.plainTextChoices.contains(plainText)
    }
    static func load(from defaults: UserDefaults?) -> ShelfShortcuts {
        guard let data = defaults?.data(forKey: key), let value = try? JSONDecoder().decode(ShelfShortcuts.self, from: data), value.isConsistent else { return .standard }
        return value
    }
    func save(to defaults: UserDefaults?) {
        guard let defaults else { return }
        if self == .standard { defaults.removeObject(forKey: Self.key) }
        else if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
