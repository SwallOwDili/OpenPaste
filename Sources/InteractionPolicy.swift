struct InteractionState: Equatable {
    var modal = false
    var attachedSheet = false
    var menuTracking = false
    var recordingShortcut = false
    var editorVisible = false
    var previewVisible = false

    var hasModalInteraction: Bool { modal || attachedSheet }
}

enum PresentationDecision: Equatable {
    case ignored
    case deferred
    case focusEditor
    case focusPreview
    case showShelf
}

struct ModifierState: Equatable {
    var command = false
    var shift = false
    var option = false
    var control = false

    var isCommandShift: Bool { command && shift && !option && !control }
}

enum InteractionPolicy {
    static func presentationDecision(for state: InteractionState) -> PresentationDecision {
        if state.hasModalInteraction || state.recordingShortcut { return .ignored }
        if state.menuTracking { return .deferred }
        if state.editorVisible { return .focusEditor }
        if state.previewVisible { return .focusPreview }
        return .showShelf
    }

    static func reverseHistoryEnabled(
        for modifiers: ModifierState,
        interaction: InteractionState,
        shelfIsKey: Bool,
        textInputFocused: Bool,
        settingsVisible: Bool
    ) -> Bool {
        // A modifier release must clear reverse mode before any event-routing
        // guard can defer or ignore the rest of the event.
        guard modifiers.isCommandShift else { return false }
        return !interaction.hasModalInteraction && !interaction.menuTracking && shelfIsKey && !textInputFocused && !settingsVisible
    }
}
