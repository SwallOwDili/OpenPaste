import AppKit

@MainActor
func runContentEditingTests() async {
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
    await settleTestSearch(duplicateStore)
    check(duplicateStore.archive.clips.count == 1 && duplicateStore.selected == existingID && duplicateStore.undoItems.isEmpty, "deduplicated new text selects the existing record without a false undo")

    // Begin with an established selection: an empty history can accidentally
    // pass because result installation defaults to its only row.
    for multiple in [false, true] {
        for deduplicated in [false, true] {
            let selectionStore = Store(ephemeral: true)
            let previous = clip("previous selection"), other = clip("other selection")
            selectionStore.archive.clips = [previous, other]
            let existingDraft = clip("")
            check(selectionStore.saveContentEdit(.text(NSAttributedString(string: "existing target")), to: .new(existingDraft)),
                  "prepare a real edited-text deduplication target")
            await settleTestSearch(selectionStore)
            selectionStore.choose(previous.id)
            if multiple { selectionStore.choose(other.id, modifiers: .command) }
            let oldSelection = selectionStore.selection
            let newDraft = clip("")
            let expectedID = deduplicated ? existingDraft.id : newDraft.id
            let text = deduplicated ? "existing target" : "new target"
            check(selectionStore.saveContentEdit(.text(NSAttributedString(string: text)), to: .new(newDraft)),
                  "save new text with previous selection: multi=\(multiple), dedup=\(deduplicated)")
            check(selectionStore.searchPending && selectionStore.selection == oldSelection,
                  "new-text choice waits for its real asynchronous snapshot")
            await settleTestSearch(selectionStore)
            check(selectionStore.selected == expectedID && selectionStore.selection == [expectedID] &&
                  selectionStore.selectionAnchor == expectedID && selectionStore.selectedClips.map(\.id) == [expectedID],
                  "new text replaces selected ID, selection and anchor: multi=\(multiple), dedup=\(deduplicated)")
            selectionStore.deleteChosen()
            await settleTestSearch(selectionStore)
            check(!selectionStore.archive.clips.contains { $0.id == expectedID } &&
                  selectionStore.archive.clips.contains { $0.id == previous.id } &&
                  selectionStore.archive.clips.contains { $0.id == other.id },
                  "deletion after creation affects the saved target, never the previous selection")
        }
    }

    // The OCR completion and new-content editor use the same production ingest
    // entry point. Supply dedicated recognized text here; this is not a Vision
    // or real GUI test, and never accesses the system clipboard.
    for multiple in [false, true] {
        for deduplicated in [false, true] {
            let extractionStore = Store(ephemeral: true)
            var picture = clip("source picture"); picture.kind = "图片"
            let other = clip("other old selection"), recognized = clip("recognized fixture")
            extractionStore.archive.clips = [picture, other] + (deduplicated ? [recognized] : [])
            await settleTestSearch(extractionStore)
            extractionStore.choose(picture.id)
            if multiple { extractionStore.choose(other.id, modifiers: .command) }
            let oldSelection = extractionStore.selection
            let extracted = clip(recognized.text)
            let expectedID = deduplicated ? recognized.id : extracted.id
            check(extractionStore.ingestAndSelect(extracted) == expectedID,
                  "OCR insertion returns the actual retained ID: multi=\(multiple), dedup=\(deduplicated)")
            check(extractionStore.searchPending && extractionStore.selection == oldSelection,
                  "OCR selection is deferred until its result is installed")
            await settleTestSearch(extractionStore)
            check(extractionStore.selected == expectedID && extractionStore.selection == [expectedID] &&
                  extractionStore.selectionAnchor == expectedID && extractionStore.selectedClips.map(\.id) == [expectedID],
                  "OCR result becomes the sole action target: multi=\(multiple), dedup=\(deduplicated)")
            extractionStore.deleteChosen()
            await settleTestSearch(extractionStore)
            check(extractionStore.archive.clips.map(\.id).contains(picture.id) &&
                  extractionStore.archive.clips.map(\.id).contains(other.id) &&
                  !extractionStore.archive.clips.contains { $0.id == expectedID },
                  "deleting extracted text preserves the source image and old multi-selection")
        }
    }

    let fallbackStore = Store(ephemeral: true)
    let retained = clip("retained visible row")
    fallbackStore.archive.clips = [retained]
    await settleTestSearch(fallbackStore)
    fallbackStore.choose(retained.id)
    fallbackStore.setRecordingLoadFailure("isolated selection failure")
    check(fallbackStore.ingestAndSelect(clip("rejected")) == nil && fallbackStore.selected == retained.id &&
          fallbackStore.selection == [retained.id] && fallbackStore.selectionAnchor == retained.id,
          "failed insertion preserves the complete previous selection")
    fallbackStore.setRecordingLoadFailure(nil)
    fallbackStore.query = "retained"
    await settleTestSearch(fallbackStore)
    _ = fallbackStore.ingestAndSelect(clip("excluded by filter"))
    await settleTestSearch(fallbackStore)
    check(fallbackStore.selected == retained.id && fallbackStore.selection == [retained.id] && fallbackStore.selectionAnchor == retained.id,
          "filtered-out insertion resolves to a valid single fallback row")
    fallbackStore.query = "no matching fixture"
    _ = fallbackStore.ingestAndSelect(clip("also excluded"))
    await settleTestSearch(fallbackStore)
    check(fallbackStore.selected == nil && fallbackStore.selection.isEmpty && fallbackStore.selectionAnchor == nil,
          "empty results clear all three programmatic selection fields")
    fallbackStore.query = "retained"
    let removed = clip("retained then deleted")
    _ = fallbackStore.ingestAndSelect(removed)
    fallbackStore.delete(removed.id)
    await settleTestSearch(fallbackStore)
    check(fallbackStore.selected == retained.id && fallbackStore.selection == [retained.id] && fallbackStore.selectionAnchor == retained.id,
          "target deleted before installation cannot leave a stale selection or anchor")

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
