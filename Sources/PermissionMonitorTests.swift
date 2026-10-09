import Foundation

func runPermissionMonitorTests() {
    var checks = 0
    func check(_ value: Bool, _ label: String) {
        guard value else { print("FAIL: \(label)"); exit(1) }
        checks += 1
    }

    check(!PermissionState(accessibility: false, eventPosting: true).directPasteAllowed && PermissionState(accessibility: false, eventPosting: true).status == "系统尚未识别授权", "missing accessibility remains conservative")
    check(!PermissionState(accessibility: true, eventPosting: false).directPasteAllowed && PermissionState(accessibility: true, eventPosting: false).status == "辅助功能已开，按键权限未生效", "event permission is independently required")
    check(PermissionState(accessibility: true, eventPosting: true).directPasteAllowed, "both current permissions allow direct paste")

    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var calls = 0, active = 0, maxActive = 0
    var queriedOffMain = true
    var published: [PermissionState] = []
    var publishedOnMain = true
    let monitor = PermissionMonitor(
        queue: DispatchQueue(label: "openpaste.permission-monitor-test"),
        query: {
            stateLock.lock()
            calls += 1; active += 1; maxActive = max(maxActive, active)
            let call = calls
            queriedOffMain = queriedOffMain && !Thread.isMainThread
            stateLock.unlock()
            started.signal(); release.wait()
            stateLock.lock(); active -= 1; stateLock.unlock()
            return PermissionState(accessibility: call.isMultiple(of: 2), eventPosting: call.isMultiple(of: 2))
        },
        publish: { state in
            publishedOnMain = publishedOnMain && Thread.isMainThread
            published.append(state)
        })

    let began = ProcessInfo.processInfo.systemUptime
    monitor.refresh()
    check(ProcessInfo.processInfo.systemUptime - began < 0.05, "slow permission query does not block refresh caller")
    var everySlowGenerationStarted = true, mainStayedResponsive = true
    for generation in 1...4 {
        everySlowGenerationStarted = everySlowGenerationStarted && started.wait(timeout: .now() + 1) == .success
        var mainTurnRan = false
        DispatchQueue.main.async { mainTurnRan = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        mainStayedResponsive = mainStayedResponsive && mainTurnRan
        if generation < 4 { for _ in 0..<20 { monitor.refresh() } }
        release.signal()
        let deadline = Date().addingTimeInterval(1)
        while published.count < generation && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    check(everySlowGenerationStarted, "each coalesced slow permission generation starts")
    check(mainStayedResponsive, "main queue remains responsive through sustained slow permission queries")
    stateLock.lock(); let finalCalls = calls, finalMaxActive = maxActive, finalOffMain = queriedOffMain; stateLock.unlock()
    check(finalCalls == 4, "repeated refreshes coalesce to one follow-up per slow generation")
    check(finalMaxActive == 1 && finalOffMain, "permission queries are serial and off main")
    let expected = [false, true, false, true].map { PermissionState(accessibility: $0, eventPosting: $0) }
    check(publishedOnMain && published == expected, "every completed slow sample is published on main in query order")
    print("Permission monitor: \(checks) checks passed")
}
