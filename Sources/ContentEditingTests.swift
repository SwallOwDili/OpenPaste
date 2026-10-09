import AppKit

func runContentEditingTests() {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { print("FAIL: \(label)"); exit(1) }
        checks += 1
        print("PASS: \(label)")
    }
    func clip(_ text: String) -> Clip {
        Clip(source: "Fixture", sourceID: "fixture.app", kind: "文字", title: text, text: text, parts: [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]])
    }

    let store = Store(ephemeral: true)
    var original = clip("old text")
    original.created = Date(timeIntervalSince1970: 1_700_000_000)
    original.ocrText = "existing auxiliary metadata"
    store.archive.clips = [original]
    let staleTarget = store.contentEditTarget(for: original)

    store.addBoard("Pinned")
    let boardID = store.archive.boards[0].id
    var renamed = store.archive.clips[0]
    renamed.title = "Latest name"
    renamed.userLabel = "Latest name"
    store.replace(renamed, label: "重命名")
    store.pin(store.archive.clips[0], to: boardID)

    let rich = NSAttributedString(string: "new rich text", attributes: [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.systemRed])
    check(store.saveContentEdit(.text(rich), to: staleTarget), "stale text edit saves against current record")
    let updated = store.archive.clips[0]
    check(updated.text == "new rich text" && updated.kind == "文字", "text fields are updated")
    check(updated.userLabel == "Latest name" && updated.title == "Latest name" && updated.boards == [boardID], "concurrent rename and favorite are preserved")
    check(updated.created == original.created && updated.source == original.source && updated.sourceID == original.sourceID && updated.ocrText == original.ocrText, "existing record metadata is preserved")
    check(updated.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont != nil, "rich text bytes are retained")
    store.undoItemChange()
    check(store.archive.clips[0].text == "old text" && store.archive.clips[0].userLabel == "Latest name" && store.archive.clips[0].boards == [boardID], "edit undo restores latest pre-edit record")

    let colorSnapshot = store.archive.clips[0]
    let colorTarget = store.contentEditTarget(for: colorSnapshot)
    var colorRename = store.archive.clips[0]
    colorRename.title = "Brand color"
    colorRename.userLabel = "Brand color"
    store.replace(colorRename, label: "重命名")
    check(store.saveContentEdit(.color("1a2b3c"), to: colorTarget, label: "颜色"), "color edit saves")
    let color = store.archive.clips[0]
    check(color.text == "#1A2B3C" && color.kind == "颜色" && color.userLabel == "Brand color" && color.title == "Brand color", "color content is normalized without overwriting latest name")
    check(color.parts == [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("#1A2B3C".utf8))]], "color edit stores plain color content")

    let deletedStore = Store(ephemeral: true)
    let doomed = clip("delete while editing")
    deletedStore.archive.clips = [doomed]
    let deletedTarget = deletedStore.contentEditTarget(for: doomed)
    deletedStore.delete(doomed.id)
    let undoCount = deletedStore.undoItems.count
    check(!deletedStore.saveContentEdit(.text(NSAttributedString(string: "must not return")), to: deletedTarget), "deleted existing edit reports failure")
    check(deletedStore.archive.clips.isEmpty && deletedStore.undoItems.count == undoCount, "deleted existing edit is not resurrected or added to undo")

    let newStore = Store(ephemeral: true)
    let draft = clip("")
    let newTarget = newStore.contentEditTarget(for: draft)
    check(newStore.saveContentEdit(.text(NSAttributedString(string: "created text")), to: newTarget), "new text is created")
    check(newStore.archive.clips.count == 1 && newStore.archive.clips[0].id == draft.id && newStore.archive.clips[0].text == "created text", "new text uses ingest and keeps its draft identity")
    newStore.undoItemChange()
    check(newStore.archive.clips.isEmpty, "new text participates in item undo")

    let duplicateStore = Store(ephemeral: true)
    let firstDraft = clip("")
    check(duplicateStore.saveContentEdit(.text(NSAttributedString(string: "same text")), to: .new(firstDraft)), "duplicate fixture is created through content editing")
    let existingID = duplicateStore.archive.clips[0].id
    duplicateStore.undoItems.removeAll()
    let duplicateDraft = clip("")
    check(duplicateStore.saveContentEdit(.text(NSAttributedString(string: "same text")), to: .new(duplicateDraft)), "duplicate new text follows ingest semantics")
    check(duplicateStore.archive.clips.count == 1 && duplicateStore.selected == existingID && duplicateStore.undoItems.isEmpty, "deduplicated new text selects the existing record without a false undo")

    let formattedStore = Store(ephemeral: true)
    check(formattedStore.saveContentEdit(.text(NSAttributedString(string: "same text")), to: .new(clip(""))), "plain rich-text fixture is created")
    formattedStore.undoItems.removeAll()
    let boldText = NSAttributedString(string: "same text", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
    check(formattedStore.saveContentEdit(.text(boldText), to: .new(clip(""))), "same text with different rich formatting saves")
    check(formattedStore.archive.clips.count == 2 && formattedStore.undoItems.count == 1, "different rich-text bytes are not deduplicated")

    let emptyStore = Store(ephemeral: true)
    check(!emptyStore.saveContentEdit(.text(NSAttributedString(string: "")), to: .new(clip(""))), "empty new text reports failure")
    check(emptyStore.archive.clips.isEmpty && emptyStore.undoItems.isEmpty && emptyStore.message == "内容为空，未创建", "empty new text gives explicit feedback without changing history")

    let oversizedStore = Store(ephemeral: true)
    let small = clip("small")
    oversizedStore.archive.clips = [small]
    let oversized = NSAttributedString(string: String(repeating: "x", count: 20 * 1024 * 1024 + 1))
    check(!oversizedStore.saveContentEdit(.text(oversized), to: .existing(small.id)), "content edit enforces the 20 MB item limit")
    check(oversizedStore.archive.clips[0].text == "small" && oversizedStore.undoItems.isEmpty, "oversized edit leaves content and undo unchanged")

    print("Content editing: \(checks) tests passed")
}
