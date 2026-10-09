import AppKit

func runLinkPreviewBoundaryTests() {
    var checks = 0
    func check(_ value: @autoclosure () throws -> Bool, _ name: String) {
        do { guard try value() else { print("FAIL: \(name)"); exit(1) }; checks += 1 }
        catch { print("FAIL: \(name): \(error)"); exit(1) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPaste-preview-boundary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = LinkPreviewCache(root: root.appendingPathComponent("cache"))
    let manual = ["http://127.0.0.1/", "http://[::1]/", "https://router.lan/", "https://INTRANET.CORP./", "http://printer.local/", "https://a.internal/", "https://example.com/?code=once", "https://example.com/?token=x", "https://example.com/redeem/once", "https://example.com/unsubscribe/x", "https://example.com/#credential", "https://example.com/?session_id=x"]
    for text in manual {
        let url = URL(string: text)!
        check(!LinkPreviewPolicy.automatic(url) && LinkPreviewPolicy.canLoad(url), "suspect URL requires explicit request")
        var called = false
        cache.load(text) { result in called = true; check(result == nil, "automatic suspect preview returns no result") }
        check(called && cache.requests.isEmpty && cache.jobs.isEmpty && cache.active == 0, "blocked preview never schedules networking or cache work")
    }
    for text in ["https://www.apple.com/mac/", "https://github.com/SwallOwDili/OpenPaste", "https://maps.apple.com/?q=Coffee&ll=37.7,-122.4", "https://example.com/article?id=123"] {
        check(LinkPreviewPolicy.automatic(URL(string: text)!), "ordinary public URLs remain eligible")
    }
    for text in ["file:///tmp/a", "https://user:password@example.com/", "javascript:alert(1)"] {
        check(!LinkPreviewPolicy.canLoad(URL(string: text)!), "unsafe URL forms cannot be fetched even manually")
    }
    let retryURL = "https://example.com/?code=retry"
    cache.failures[retryURL] = Date()
    cache.results[retryURL] = LinkPreviewResult(title: "explicit retry", subtitle: "example.com", image: nil, coordinate: nil)
    cache.savedAt[retryURL] = Date()
    var retried = false
    cache.load(retryURL, userInitiated: true) { result in retried = result?.title == "explicit retry" }
    check(retried && cache.failures[retryURL] == nil, "explicit retry bypasses the automatic failure cooldown")
    do {
        let history = root.appendingPathComponent("history")
        let clip = Clip(source: "Preview fixture", sourceID: "test.preview", kind: "链接", title: "original", text: "https://example.com/article", parts: [[ClipPart(type: "public.utf8-plain-text", data: Data("https://example.com/article".utf8))]])
        try HistoryStorage.write(Archive(clips: [clip]), to: history.appendingPathComponent("history.json"))
        let store = Store(root: history)
        let before = try Data(contentsOf: history.appendingPathComponent("history.json"))
        store.setRecordingLoadFailure("synthetic read-only state")
        let result = LinkPreviewResult(title: "Fetched title", subtitle: "example.com", image: nil, coordinate: nil)
        store.applyLinkPreview(result, to: clip)
        store.flush()
        check(store.archive.clips[0].linkTitle == clip.linkTitle, "read-only preview leaves memory unchanged")
        check(try Data(contentsOf: history.appendingPathComponent("history.json")) == before, "read-only preview leaves disk unchanged")
        store.setRecordingLoadFailure(nil)
        store.applyLinkPreview(result, to: clip)
        store.flush()
        check(try HistoryStorage.read(from: history.appendingPathComponent("history.json")).clips[0].linkTitle == "Fetched title\nexample.com", "writable preview metadata persists")
        let mutation = store.directoryMutation
        store.applyLinkPreview(result, to: clip)
        check(store.directoryMutation == mutation, "same preview does not trigger another save")
        store.archive.clips[0].text = "https://example.com/edited"
        store.archive.clips[0].linkTitle = "edited marker"
        store.applyLinkPreview(result, to: clip)
        check(store.archive.clips[0].linkTitle == "edited marker", "late callback cannot overwrite an edited URL")
        store.archive.clips = []
        store.applyLinkPreview(result, to: clip)
        check(store.archive.clips.isEmpty, "late callback cannot recreate a deleted entry")
        store.flush()
    } catch { print("FAIL: preview boundary: \(error)"); exit(1) }
    print("Link preview boundaries: \(checks) checks passed")
}
