import AppKit
import ApplicationServices
let required = "io.github.SwallOwDili.OpenPaste.fixture"
guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: required).first else { exit(6) }
_ = target.activate(options: [])
let deadline = Date().addingTimeInterval(3)
while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != required && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == required else {
    print("BLOCKED: synthetic test target is not frontmost"); exit(2)
}
guard CGPreflightPostEventAccess() else { print("BLOCKED: event-posting permission unavailable"); exit(3) }
guard let source = CGEventSource(stateID: .privateState) else { exit(4) }
let keys: [(CGKeyCode, Bool, CGEventFlags)] = [
    (56, true, [.maskShift]), (55, true, [.maskShift, .maskCommand]),
    (9, true, [.maskShift, .maskCommand]), (9, false, [.maskShift, .maskCommand]),
    (55, false, [.maskShift]), (56, false, [])
]
for (code, down, flags) in keys {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { exit(5) }
    event.flags = flags; event.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.02)
}
print("Posted Command-Shift-V through the system event path to the active synthetic target")

if CommandLine.arguments.contains("--cancel-after-open") {
    let openedDeadline = Date().addingTimeInterval(3)
    while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "io.github.SwallOwDili.OpenPaste" && Date() < openedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "io.github.SwallOwDili.OpenPaste" else { print("BLOCKED: panel did not activate"); exit(7) }
    for down in [true, false] {
        let escape = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)!
        escape.flags = []; escape.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
    }
    print("Posted Escape after panel activation; cancellation requested")
}
