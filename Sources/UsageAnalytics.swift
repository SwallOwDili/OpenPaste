import AppKit
import FirebaseCore
import FirebaseAnalytics

enum UsageEvent: String {
    case firstLaunch = "first_launch"
    case contentPasted = "content_pasted"
    case translationCompleted = "translation_completed"
}

/// Only fixed event names are sent. Clipboard data and user-entered settings never enter this API.
final class UsageAnalytics: ObservableObject {
    static let shared = UsageAnalytics()

    @Published var enabled = (Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil) && ((UserDefaults.standard.object(forKey: "usageAnalyticsEnabled") as? Bool) ?? true) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "usageAnalyticsEnabled")
            if enabled && !configured { start(); return }
            guard configured else { return }
            Analytics.setAnalyticsCollectionEnabled(enabled)
            if enabled {
                recordFirstLaunch()
            } else {
                Analytics.resetAnalyticsData()
            }
        }
    }

    private var configured = false
    var available: Bool { Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil }

    func start() {
        guard enabled, !configured, available else { return }
        FirebaseApp.configure()
        configured = true
        Analytics.setAnalyticsCollectionEnabled(enabled)
        recordFirstLaunch()
    }

    private func recordFirstLaunch() {
        if !UserDefaults.standard.bool(forKey: "usageAnalyticsFirstLaunchRecorded") {
            record(.firstLaunch)
            UserDefaults.standard.set(true, forKey: "usageAnalyticsFirstLaunchRecorded")
        }
    }

    func record(_ event: UsageEvent) {
        guard configured, enabled else { return }
        Analytics.logEvent(event.rawValue, parameters: nil)
    }
}

// A successful send is observable; the receiving app accepting the paste is not.
enum PasteShortcut {
    static func send(makeEvent: (Bool) -> CGEvent?, post: (CGEvent) -> Void, didSend: () -> Void) -> Bool {
        guard let down = makeEvent(true), let up = makeEvent(false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        post(down); post(up); didSend()
        return true
    }
}
