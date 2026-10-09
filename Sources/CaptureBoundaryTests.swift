import AppKit

func runCaptureBoundaryTests() {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { print("FAIL: \(label)"); exit(1) }
        checks += 1
        print("PASS: \(label)")
    }

    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = Store(ephemeral: true)
    let ignored = ClipboardCaptureSource(name: "Ignored Fixture", bundleID: "example.capture.ignored")
    let allowed = ClipboardCaptureSource(name: "Allowed Fixture", bundleID: "example.capture.allowed")
    store.ignored = ignored.bundleID

    pasteboard.clearContents()
    pasteboard.setString("ignored first capture", forType: .string)
    let ignoredChange = pasteboard.changeCount
    store.capture(force: true, pasteboard: pasteboard, sourceOverride: ignored)
    check(store.archive.clips.isEmpty && store.captureNotice.contains("已排除"), "ignored source rejects the first forced capture")

    store.capture(force: true, pasteboard: pasteboard, sourceOverride: allowed)
    check(pasteboard.changeCount == ignoredChange && store.archive.clips.isEmpty && store.captureNotice.contains("已排除"), "same change count keeps its ignored source ownership")

    pasteboard.clearContents()
    pasteboard.setString("temporary selection", forType: .string)
    pasteboard.clearContents()
    pasteboard.setString("ignored first capture", forType: .string)
    store.recordRestoredClipboardChange(from: ignoredChange, pasteboard: pasteboard)
    store.capture(force: true, pasteboard: pasteboard, sourceOverride: allowed)
    check(store.archive.clips.isEmpty && store.captureNotice.contains("已排除"), "restored change count inherits ignored source ownership")

    let sensitiveItem = NSPasteboardItem()
    sensitiveItem.setString("sensitive fixture", forType: .string)
    sensitiveItem.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    pasteboard.clearContents()
    pasteboard.writeObjects([sensitiveItem])
    store.capture(force: true, pasteboard: pasteboard, sourceOverride: allowed)
    check(store.archive.clips.isEmpty && store.captureNotice.contains("敏感或临时标记"), "sensitive marker rejects capture")

    pasteboard.clearContents()
    pasteboard.setString("allowed after real change", forType: .string)
    store.capture(pasteboard: pasteboard, sourceOverride: allowed)
    check(store.archive.clips.count == 1, "a real clipboard change can be captured")
    check(store.archive.clips.first?.text == "allowed after real change", "captured content comes from the changed pasteboard")
    check(store.archive.clips.first?.source == allowed.name && store.archive.clips.first?.sourceID == allowed.bundleID, "new change records the correct source name and bundle ID")

    let allowedChange = pasteboard.changeCount
    let allowedID = store.archive.clips[0].id
    store.delete(allowedID)
    pasteboard.clearContents()
    pasteboard.setString("temporary selection", forType: .string)
    pasteboard.clearContents()
    pasteboard.setString("allowed after real change", forType: .string)
    store.recordRestoredClipboardChange(from: allowedChange, pasteboard: pasteboard)
    store.capture(force: true, pasteboard: pasteboard, sourceOverride: ignored)
    check(store.archive.clips.first?.source == allowed.name && store.archive.clips.first?.sourceID == allowed.bundleID, "restored allowed content retains its original source")

    let newSource = ClipboardCaptureSource(name: "New Fixture", bundleID: "example.capture.new")
    pasteboard.clearContents()
    pasteboard.setString("genuinely new copy", forType: .string)
    store.capture(pasteboard: pasteboard, sourceOverride: newSource)
    check(store.archive.clips.first?.text == "genuinely new copy" && store.archive.clips.first?.sourceID == newSource.bundleID, "genuinely new clipboard content can acquire a new source")

    print("\(checks) capture boundary tests passed")
}
