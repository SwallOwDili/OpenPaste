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

    // Exercise production cache subscriptions without contacting a network service.
    // Occupy the two network slots, then finish controlled requests explicitly.
    func waitFor(_ name: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        check(condition(), name)
    }
    func settle(_ store: Store) {
        waitFor("real asynchronous search finishes") {
            !store.searchPending && store.searchAppliedGeneration == store.searchRequestGeneration
        }
    }
    let subscriptions = LinkPreviewCache(root: root.appendingPathComponent("subscriptions"))
    defer { subscriptions.cancelAll() }
    let sharedResult = LinkPreviewResult(title: "shared", subtitle: "example.com")
    for running in [false, true] {
        let url = "https://example.com/shared-\(running)"
        subscriptions.active = 2
        var offscreenCallbacks = 0, visibleCallbacks = 0
        let offscreen = subscriptions.load(url) { _ in offscreenCallbacks += 1 }
        let visible = subscriptions.load(url) { value in
            visibleCallbacks += 1
            check(value?.title == sharedResult.title, "visible subscriber receives the successful shared result")
        }
        waitFor("shared request reaches the network queue") { subscriptions.jobs.contains { $0.0 == url } }
        let request = subscriptions.requests[url]!
        check(offscreen != nil && visible != nil && subscriptions.pending[url]?.count == 2, "same URL coalesces two subscribers")
        if running {
            // Simulate a provider that has started but has not returned yet.
            subscriptions.jobs.removeAll { $0.0 == url }
            request.usesNetworkSlot = true; subscriptions.active = 1
        }
        subscriptions.cancel(offscreen)
        check(!request.cancelled && subscriptions.pending[url]?.count == 1 && (running || subscriptions.jobs.contains { $0.0 == url }),
              "offscreen subscriber cannot cancel a queued or running visible request")
        subscriptions.finish(url, sharedResult, request: request, cachedAt: Date())
        waitFor("shared completion reaches visible subscriber") { visibleCallbacks == 1 }
        check(offscreenCallbacks == 0 && subscriptions.pending[url] == nil && subscriptions.requests[url] == nil,
              "detached subscriber receives no callback and completed subscription state is released")
        check(!running || subscriptions.active == 0, "shared completion releases the network slot once")
        subscriptions.cancel(visible)
    }
    let lastURL = "https://example.com/last-subscriber"
    subscriptions.active = 2
    var cancelledCallbacks = 0, replacementCallbacks = 0
    let old = subscriptions.load(lastURL) { _ in cancelledCallbacks += 1 }
    waitFor("last-subscriber request is queued") { subscriptions.jobs.contains { $0.0 == lastURL } }
    let oldRequest = subscriptions.requests[lastURL]!
    subscriptions.cancel(old)
    check(oldRequest.cancelled && subscriptions.requests[lastURL] == nil && subscriptions.pending[lastURL] == nil && subscriptions.jobs.isEmpty,
          "last queued subscriber cancels unused work")
    let replacement = subscriptions.load(lastURL) { _ in replacementCallbacks += 1 }
    waitFor("replacement request is queued") { subscriptions.jobs.contains { $0.0 == lastURL } }
    let replacementRequest = subscriptions.requests[lastURL]!
    subscriptions.cancel(old)
    check(!replacementRequest.cancelled && subscriptions.pending[lastURL]?.count == 1,
          "stale subscription cannot cancel a replacement request")
    subscriptions.finish(lastURL, sharedResult, request: oldRequest, cachedAt: Date())
    subscriptions.finish(lastURL, sharedResult, request: replacementRequest, cachedAt: Date())
    waitFor("replacement completion is delivered") { replacementCallbacks == 1 }
    check(cancelledCallbacks == 0, "cancelled request completion never reaches the detached subscriber")
    subscriptions.cancel(replacement)

    let runningURL = "https://example.com/running-orphan"
    subscriptions.active = 2
    let detached = subscriptions.load(runningURL) { _ in cancelledCallbacks += 1 }
    waitFor("orphan request is queued") { subscriptions.jobs.contains { $0.0 == runningURL } }
    let runningRequest = subscriptions.requests[runningURL]!
    subscriptions.jobs.removeAll { $0.0 == runningURL }
    runningRequest.usesNetworkSlot = true; subscriptions.active = 1
    subscriptions.cancel(detached)
    check(!runningRequest.cancelled && subscriptions.pending[runningURL] == nil, "running request may finish after its last subscriber leaves")
    var joined = 0
    subscriptions.load(runningURL) { _ in joined += 1 }
    check(subscriptions.requests[runningURL] === runningRequest && subscriptions.pending[runningURL]?.count == 1,
          "new visible subscriber rejoins the existing running request")
    subscriptions.finish(runningURL, sharedResult, request: runningRequest, cachedAt: Date())
    waitFor("rejoined subscriber receives completion") { joined == 1 }
    check(cancelledCallbacks == 0 && subscriptions.active == 0, "running detachment does not deliver late callbacks or leak slots")

    let sharedCardCache = LinkPreviewCache(root: root.appendingPathComponent("shared-card-state"))
    let sharedCardStore = Store(root: root.appendingPathComponent("shared-card-history"), ephemeral: true)
    let sharedCardURL = "https://example.com/?token=two-visible-cards"
    let sharedClipA = Clip(source: "Preview fixture", sourceID: "test.card.a", kind: "链接", title: "first", text: sharedCardURL,
                           parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(sharedCardURL.utf8))]])
    let sharedClipB = Clip(source: "Preview fixture", sourceID: "test.card.b", kind: "链接", title: "second", text: sharedCardURL,
                           parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(sharedCardURL.utf8))]])
    sharedCardStore.archive.clips = [sharedClipA, sharedClipB]
    settle(sharedCardStore)
    let firstCard = LinkCardPreview(cache: sharedCardCache)
    let secondCard = LinkCardPreview(cache: sharedCardCache)
    let sharedImage = NSImage(size: NSSize(width: 2, height: 2))
    let sharedGeneration = sharedCardStore.searchAppliedGeneration
    sharedCardCache.active = 2
    firstCard.update(clip: sharedClipA, store: sharedCardStore, enabled: true, ready: true, generation: sharedGeneration, userInitiated: true)
    secondCard.update(clip: sharedClipB, store: sharedCardStore, enabled: true, ready: true, generation: sharedGeneration, userInitiated: true)
    waitFor("two visible cards join one manual request") { sharedCardCache.jobs.contains { $0.0 == sharedCardURL } }
    let sharedRequest = sharedCardCache.requests[sharedCardURL]!
    sharedCardCache.jobs.removeAll { $0.0 == sharedCardURL }
    sharedRequest.usesNetworkSlot = true; sharedCardCache.active = 1
    let sharedPreview = LinkPreviewResult(title: "Shared title", subtitle: "example.com", image: sharedImage)
    sharedCardCache.finish(sharedCardURL, sharedPreview, request: sharedRequest, cachedAt: Date())
    waitFor("both visible cards install the shared preview") { firstCard.result?.image === sharedImage && secondCard.result?.image === sharedImage }
    check(firstCard.userRequested && secondCard.userRequested,
          "metadata refresh cannot revoke either visible card's manual authorization")
    settle(sharedCardStore)
    check(sharedCardStore.archive.clips.allSatisfy { $0.linkTitle == "Shared title\nexample.com" },
          "shared preview metadata is written once without dropping the second card")

    let modelCache = LinkPreviewCache(root: root.appendingPathComponent("card-state"))
    let cardStore = Store(root: root.appendingPathComponent("card-history"), ephemeral: true)
    let url = "https://example.com/?token=manual-refresh"
    let clip = Clip(source: "Preview fixture", sourceID: "test.card", kind: "链接", title: "original", text: url,
                    parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(url.utf8))]])
    cardStore.archive.clips = [clip]
    settle(cardStore)
    let image = NSImage(size: NSSize(width: 2, height: 2))
    let preview = LinkPreviewResult(title: "Manual title", subtitle: "example.com", image: image)
    func seedManualPreview() { modelCache.results[url] = preview; modelCache.savedAt[url] = Date() }
    seedManualPreview()
    let card = LinkCardPreview(cache: modelCache)
    func updateCard(_ clip: Clip, ready: Bool = true, enabled: Bool = true, manual: Bool = false) {
        card.update(clip: clip, store: cardStore, enabled: enabled, ready: ready,
                    generation: cardStore.searchAppliedGeneration, userInitiated: manual)
    }
    updateCard(clip)
    check(card.finished && card.result == nil && modelCache.requests.isEmpty, "restricted cached URL still requires this card's explicit request")
    let beforeMetadata = cardStore.searchAppliedGeneration
    updateCard(clip, manual: true)
    check(card.result?.title == preview.title && card.result?.image === image && card.userRequested,
          "manual preview installs the image and explicit-request state")
    waitFor("manual preview metadata write is deferred until callbacks finish") {
        cardStore.archive.clips[0].linkTitle == "Manual title\nexample.com"
    }
    check(cardStore.archive.clips[0].linkTitle == "Manual title\nexample.com",
          "manual success writes metadata and triggers a real result refresh")
    updateCard(clip, ready: false)
    check(card.result?.image === image && card.userRequested, "pending result refresh keeps the successful manual preview")
    settle(cardStore)
    check(cardStore.searchAppliedGeneration > beforeMetadata, "metadata search refresh installs a new generation")
    modelCache.results.removeAll(); modelCache.savedAt.removeAll()
    updateCard(cardStore.filtered[0])
    check(card.result?.title == preview.title && card.result?.image === image && card.userRequested && modelCache.requests.isEmpty,
          "installed refreshed result preserves the manual image without fetching or cache access")
    cardStore.query = "Manual title"; settle(cardStore)
    updateCard(cardStore.filtered[0])
    check(card.result?.image === image && modelCache.requests.isEmpty, "unrelated search generation also retains the loaded preview")
    updateCard(clip, ready: false, enabled: false)
    check(card.result == nil && !card.userRequested && card.finished, "disabling previews clears the card even while results are pending")
    updateCard(clip)
    check(card.result == nil && !card.userRequested && modelCache.requests.isEmpty, "reenabling does not silently authorize a restricted URL")
    seedManualPreview(); updateCard(clip, manual: true)
    cardStore.invalidatePendingStorageCallbacks()
    updateCard(clip, ready: false)
    check(card.result == nil && !card.userRequested, "directory changes clear the old preview and authorization before results arrive")
    settle(cardStore)
    updateCard(clip)
    check(card.result == nil && modelCache.requests.isEmpty, "directory refresh does not reuse another directory's explicit authorization")
    seedManualPreview(); updateCard(clip, manual: true)
    var edited = clip; edited.text = "https://example.com/?token=edited"
    updateCard(edited)
    check(card.result == nil && !card.userRequested && modelCache.requests.isEmpty, "editing the URL drops the old image and requires a new explicit request")
    print("Link preview boundaries: \(checks) checks passed")
}
