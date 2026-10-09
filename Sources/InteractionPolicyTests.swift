import Foundation

func runInteractionPolicyTests() {
    var checks = 0
    func expect<T: Equatable>(_ actual: T, _ expected: T, _ scenario: String) {
        guard actual == expected else {
            print("FAIL: \(scenario) (expected \(expected), got \(actual))")
            exit(1)
        }
        checks += 1
    }
    func decision(_ state: InteractionState) -> PresentationDecision {
        InteractionPolicy.presentationDecision(for: state)
    }
    func reverse(
        _ modifiers: ModifierState,
        interaction: InteractionState = InteractionState(),
        shelfIsKey: Bool = true,
        textInputFocused: Bool = false,
        settingsVisible: Bool = false
    ) -> Bool {
        InteractionPolicy.reverseHistoryEnabled(
            for: modifiers,
            interaction: interaction,
            shelfIsKey: shelfIsKey,
            textInputFocused: textInputFocused,
            settingsVisible: settingsVisible
        )
    }

    expect(decision(InteractionState()), .showShelf, "plain invocation shows the shelf")
    expect(decision(InteractionState(recordingShortcut: true)), .ignored, "shortcut recording ignores invocation")
    expect(decision(InteractionState(modal: true, menuTracking: true, editorVisible: true)), .ignored, "modal interaction blocks before menu or auxiliary focus")
    expect(decision(InteractionState(attachedSheet: true)), .ignored, "a real attached sheet blocks even when modalShowing is false")
    expect(decision(InteractionState(menuTracking: true, editorVisible: true)), .deferred, "menu tracking defers auxiliary focus")
    expect(decision(InteractionState(editorVisible: true)), .focusEditor, "visible editor receives invocation focus")
    expect(decision(InteractionState(previewVisible: true)), .focusPreview, "visible preview receives invocation focus")
    expect(decision(InteractionState(editorVisible: true, previewVisible: true)), .focusEditor, "editor takes priority over preview and preserves its draft")

    let commandShift = ModifierState(command: true, shift: true)
    expect(reverse(commandShift), true, "Command-Shift enables reverse order on the focused shelf")
    expect(reverse(ModifierState(command: true), interaction: InteractionState(menuTracking: true)), false, "Shift release clears reverse order during menu tracking")
    expect(reverse(ModifierState(shift: true), interaction: InteractionState(modal: true)), false, "Command release clears reverse order during a modal interaction")
    expect(reverse(commandShift, interaction: InteractionState(menuTracking: true)), false, "held Command-Shift stays disabled while a menu tracks")
    expect(reverse(commandShift, interaction: InteractionState(modal: true)), false, "held Command-Shift stays disabled during a modal interaction")
    expect(reverse(commandShift, interaction: InteractionState(attachedSheet: true)), false, "attached sheet disables reverse order independently of modalShowing")
    expect(reverse(commandShift, shelfIsKey: false), false, "unfocused shelf cannot enable reverse order")
    expect(reverse(commandShift, textInputFocused: true), false, "text input keeps normal editing order")
    expect(reverse(commandShift, settingsVisible: true), false, "settings keeps reverse order disabled")
    expect(reverse(ModifierState(command: true, shift: true, option: true)), false, "extra modifiers do not enter reverse order")

    print("PASS: \(checks) interaction policy scenarios")
}
