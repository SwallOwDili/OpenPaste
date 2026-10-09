import Foundation

// Local acceptance only: records timing, never clipboard content or settings.
enum AcceptanceMetrics {
    private static var timer: Timer?
    private static var observer: CFRunLoopObserver?
    private static var previous = 0.0
    private static var intervalStart = 0.0
    private static var maxDelay = 0.0
    private static var maxDelayAt = 0.0
    private static var maxDelayMode = "none"
    private static var turnStart = 0.0
    private static var maxTurn = 0.0
    private static var maxTurnAt = 0.0
    private static var samples = 0
    private static var starting = false

    static func start() {
        guard AppEnvironment.current.acceptanceMode, timer == nil else { return }
        let launchTailStart = ProcessInfo.processInfo.systemUptime
        previous = launchTailStart
        intervalStart = previous
        starting = true
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            let now = ProcessInfo.processInfo.systemUptime
            if activity.contains(.afterWaiting) { turnStart = now }
            else if activity.contains(.beforeWaiting), turnStart > 0 {
                let duration = now - turnStart
                if duration > maxTurn { maxTurn = duration; maxTurnAt = now }
                turnStart = 0
            }
        }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        DispatchQueue.main.async {
            let now = ProcessInfo.processInfo.systemUptime
            print(String(format: "ACCEPTANCE launch.delegate-tail-ms=%.1f uptime=%.3f", (now - launchTailStart) * 1000, launchTailStart))
            fflush(stdout)
            previous = now; intervalStart = now; maxDelay = 0; maxDelayAt = 0; maxDelayMode = "none"; maxTurn = 0; maxTurnAt = 0; samples = 0; starting = false
        }
        let heartbeat = Timer(timeInterval: 0.02, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            guard !starting else { previous = now; return }
            let delay = max(0, now - previous - 0.02)
            if delay > maxDelay {
                maxDelay = delay; maxDelayAt = now
                maxDelayMode = RunLoop.main.currentMode?.rawValue ?? "none"
            }
            previous = now; samples += 1
            if now - intervalStart >= 5 {
                print(String(format: "ACCEPTANCE main-loop max-delay-ms=%.1f max-turn-ms=%.1f samples=%d delay-at=%.3f turn-at=%.3f mode=%@ uptime=%.3f", maxDelay * 1000, maxTurn * 1000, samples, maxDelayAt, maxTurnAt, maxDelayMode, now))
                fflush(stdout)
                maxDelay = 0; maxDelayAt = 0; maxDelayMode = "none"; maxTurn = 0; maxTurnAt = 0; samples = 0; intervalStart = now
            }
        }
        timer = heartbeat
        RunLoop.main.add(heartbeat, forMode: .common)
    }

    // Separates synchronous work from the wait for the next main-queue turn; neither is pixel latency.
    static func begin(_ operation: String) -> (() -> Void) {
        guard AppEnvironment.current.acceptanceMode else { return {} }
        let start = ProcessInfo.processInfo.systemUptime
        return {
            let syncEnd = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                let delivered = ProcessInfo.processInfo.systemUptime
                print(String(format: "ACCEPTANCE %@ next-turn-ms=%.1f sync-ms=%.1f queue-ms=%.1f uptime=%.3f", operation, (delivered - start) * 1000, (syncEnd - start) * 1000, (delivered - syncEnd) * 1000, start))
                fflush(stdout)
            }
        }
    }
}
