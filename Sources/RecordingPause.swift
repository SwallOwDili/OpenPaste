import Foundation

enum RecordingPauseState: Equatable {
    case recording
    case indefinitely
    case until(Date)
    case expired

    var isPaused: Bool {
        switch self {
        case .recording, .expired: false
        case .indefinitely, .until: true
        }
    }
}

enum RecordingPauseControlAction: Equatable {
    case pause
    case resume
    case enable
    case retryLoad
    case retrySave
    case unavailable
}

struct RecordingPauseControl: Equatable {
    let action: RecordingPauseControlAction
    let status: String
    let buttonTitle: String
}

struct RecordingPauseTimerToken: Equatable {
    fileprivate let generation: Int
    let deadline: Date
}

struct RecordingPauseTimerSchedule {
    private(set) var generation = 0
    private(set) var deadline: Date?

    mutating func replace(with deadline: Date) -> RecordingPauseTimerToken {
        generation += 1
        self.deadline = deadline
        return RecordingPauseTimerToken(generation: generation, deadline: deadline)
    }

    mutating func cancel() {
        generation += 1
        deadline = nil
    }

    func remainingDelay(for token: RecordingPauseTimerToken, now: Date) -> TimeInterval? {
        guard token.generation == generation, deadline == token.deadline else { return nil }
        return max(0, token.deadline.timeIntervalSince(now))
    }
}

struct RecordingPauseReasons {
    private(set) var recordingAccepted = true
    private(set) var userPaused = false
    private(set) var loadFailure: String?
    private(set) var saveFailure: String?
    private(set) var temporaryPauseCount = 0

    var isPaused: Bool { !recordingAccepted || userPaused || loadFailure != nil || saveFailure != nil || temporaryPauseCount > 0 }
    var hasStorageFailure: Bool { loadFailure != nil || saveFailure != nil }
    var control: RecordingPauseControl {
        let title = userPaused ? "继续记录" : "暂停记录"
        if let loadFailure {
            return RecordingPauseControl(action: .retryLoad, status: "历史读取失败：\(loadFailure)", buttonTitle: "重试读取")
        }
        if let saveFailure {
            return RecordingPauseControl(action: .retrySave, status: "历史保存失败：\(saveFailure)", buttonTitle: "重试保存")
        }
        if !recordingAccepted {
            return RecordingPauseControl(action: .enable, status: "尚未启用记录", buttonTitle: "启用记录")
        }
        if userPaused {
            return RecordingPauseControl(action: .resume, status: "记录已暂停", buttonTitle: title)
        }
        if temporaryPauseCount > 0 {
            return RecordingPauseControl(action: .unavailable, status: "正在处理数据，暂时暂停记录", buttonTitle: title)
        }
        return RecordingPauseControl(action: .pause, status: "正在记录剪贴板", buttonTitle: title)
    }

    mutating func setRecordingAccepted(_ value: Bool) { recordingAccepted = value }
    mutating func setUserPaused(_ value: Bool) { userPaused = value }
    mutating func setLoadFailure(_ detail: String?) { loadFailure = detail }
    mutating func setSaveFailure(_ detail: String?) { saveFailure = detail }
    mutating func beginTemporaryPause() { temporaryPauseCount += 1 }
    mutating func endTemporaryPause() { temporaryPauseCount = max(0, temporaryPauseCount - 1) }
}

struct RecordingPausePersistence {
    private static let indefiniteKey = "recordingPauseIndefinite"
    private static let untilKey = "recordingPauseUntil"

    let defaults: UserDefaults
    let now: () -> Date

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    @discardableResult
    func restore() -> RecordingPauseState {
        if defaults.bool(forKey: Self.indefiniteKey) { return .indefinitely }
        guard let timestamp = defaults.object(forKey: Self.untilKey) as? Double else { return .recording }
        let deadline = Date(timeIntervalSince1970: timestamp)
        guard deadline > now() else { return .expired }
        return .until(deadline)
    }

    @discardableResult
    func pauseIndefinitely() -> RecordingPauseState {
        defaults.set(true, forKey: Self.indefiniteKey)
        defaults.removeObject(forKey: Self.untilKey)
        return .indefinitely
    }

    @discardableResult
    func pause(for interval: TimeInterval) -> RecordingPauseState {
        pause(until: now().addingTimeInterval(max(0, interval)))
    }

    @discardableResult
    func pause(until deadline: Date) -> RecordingPauseState {
        guard deadline > now() else { clear(); return .recording }
        defaults.removeObject(forKey: Self.indefiniteKey)
        defaults.set(deadline.timeIntervalSince1970, forKey: Self.untilKey)
        return .until(deadline)
    }

    func clear() {
        defaults.removeObject(forKey: Self.indefiniteKey)
        defaults.removeObject(forKey: Self.untilKey)
    }
}
