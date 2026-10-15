// Standalone benchmark support; not part of the application target.
// The runner compiles this with unmodified production sources and a replaced
// terminal entry point. It does not open windows or capture the clipboard.
import Foundation

private final class SearchMainQueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "search.benchmark.probe")
    private var timer: DispatchSourceTimer?
    private var maximum = 0.0
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            let submitted = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let self else { return }
                let delay = ProcessInfo.processInfo.systemUptime - submitted
                self.lock.lock(); self.maximum = max(self.maximum, delay); self.lock.unlock()
            }
        }
        self.timer = timer
        timer.resume()
    }
    func reset() { lock.lock(); maximum = 0; lock.unlock() }
    var milliseconds: Double { lock.lock(); defer { lock.unlock() }; return maximum * 1000 }
    func stop() { timer?.cancel(); timer = nil }
}

@MainActor
func runStoreSearchBenchmark() async {
    func fail(_ message: String) -> Never { print("BENCHMARK FAIL: " + message); exit(1) }
    func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }
    func settle(_ store: Store) async {
        #if !SEARCH_BASELINE
        guard await store.awaitLatestSearch(timeout: 60) else { fail("latest Store search did not complete") }
        #endif
    }
    let arguments = CommandLine.arguments
    guard arguments.count == 2 else { fail("supply exactly one synthetic history directory") }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
    let fixtureParent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/search-performance/fixtures", isDirectory: true).standardizedFileURL
    guard root.deletingLastPathComponent() == fixtureParent else { fail("only prepared repository fixture directories are allowed") }
    let manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture-manifest.json"))) as! [String: Any]
    guard manifest["synthetic_only"] as? Bool == true else { fail("missing synthetic fixture provenance") }
    let readingStart = ProcessInfo.processInfo.systemUptime
    let archive: Archive
    do { archive = try HistoryStorage.read(from: root.appendingPathComponent("history.json")) }
    catch { fail("native HistoryStorage load failed: \(error)") }
    let readingMS = (ProcessInfo.processInfo.systemUptime - readingStart) * 1000
    guard archive.clips.count == manifest["items"] as? Int else { fail("native load count differs from manifest") }
    let queries = ["learning-web-deep-tail", "learn", "learning", "learning-we", "learning-web", "no-such-fixture-word",
                   "synthetic", "中文", "CAFÉ", "🌟", "Fixture 3", "ocrmarker00013", "linktitlemarker00016",
                   "labelmarker00097", "tailmarker00008", " tailmarker", "needle", " ", "", "learning-web-deep-tail", "学习"]
    // Run the exact old predicate only before timings. Full ID arrays, not counts,
    // validate matching and order independently from the new pipeline.
    var expected: [String: [UUID]] = [:]
    for query in Set(queries) {
        expected[query] = archive.clips.filter { clip in
            query.isEmpty || clip.title.localizedCaseInsensitiveContains(query) || clip.text.localizedCaseInsensitiveContains(query) ||
            clip.source.localizedCaseInsensitiveContains(query) || (clip.ocrText?.localizedCaseInsensitiveContains(query) ?? false) ||
            (clip.linkTitle?.localizedCaseInsensitiveContains(query) ?? false) || (clip.userLabel?.localizedCaseInsensitiveContains(query) ?? false)
        }.map(\.id)
    }
    let probe = SearchMainQueueProbe()
    probe.start()
    defer { probe.stop() }
    try? await Task.sleep(nanoseconds: 30_000_000)
    #if SEARCH_BASELINE
    let variant = "baseline"
    #else
    let variant = "candidate"
    #endif
    emit(["event": "environment", "variant": variant, "fixture": root.lastPathComponent,
          "count": archive.clips.count, "history_sha256": manifest["history_sha256"]!, "native_read_ms": readingMS,
          "processor_count": ProcessInfo.processInfo.processorCount, "os": ProcessInfo.processInfo.operatingSystemVersionString,
          "scope": "headless Store submission through committed model; no window/render/IME measurement"])
    let store = Store(ephemeral: true)
    await settle(store)
    probe.reset()
    let coldStart = ProcessInfo.processInfo.systemUptime
    store.archive = archive
    store.query = queries[0]
    let coldSubmit = (ProcessInfo.processInfo.systemUptime - coldStart) * 1000
    await settle(store)
    let coldComplete = (ProcessInfo.processInfo.systemUptime - coldStart) * 1000
    guard store.filtered.map(\.id) == expected[queries[0]] else { fail("cold IDs differ from original predicate") }
    try? await Task.sleep(nanoseconds: 2_000_000)
    emit(["event": "search", "state": "cold-native-cache", "variant": variant, "fixture": root.lastPathComponent,
          "query_index": 0, "submit_main_ms": coldSubmit, "complete_ms": coldComplete,
          "main_queue_max_delay_ms": probe.milliseconds, "result_count": store.filtered.count, "ids_match_oracle": true])
    for (index, query) in queries.dropFirst().enumerated() {
        probe.reset()
        let start = ProcessInfo.processInfo.systemUptime
        store.query = query
        let submit = (ProcessInfo.processInfo.systemUptime - start) * 1000
        await settle(store)
        let complete = (ProcessInfo.processInfo.systemUptime - start) * 1000
        guard store.filtered.map(\.id) == expected[query] else { fail("query \(index + 1) IDs differ from original predicate") }
        try? await Task.sleep(nanoseconds: 2_000_000)
        emit(["event": "search", "state": "warm-native-cache", "variant": variant, "fixture": root.lastPathComponent,
              "query_index": index + 1, "submit_main_ms": submit, "complete_ms": complete,
              "main_queue_max_delay_ms": probe.milliseconds, "result_count": store.filtered.count, "ids_match_oracle": true])
    }
    emit(["event": "complete", "variant": variant, "fixture": root.lastPathComponent, "verified_queries": queries.count])
}
