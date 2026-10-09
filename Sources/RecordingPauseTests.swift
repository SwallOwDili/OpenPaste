import AppKit
import Foundation

func runRecordingPauseTests() {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { print("FAIL: \(label)"); exit(1) }
        checks += 1
    }

    let suite = "OpenPaste.RecordingPauseTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let persistence = RecordingPausePersistence(defaults: defaults, now: { clock })

    check(persistence.restore() == .recording, "fresh profile records normally")
    check(persistence.pauseIndefinitely() == .indefinitely && persistence.restore() == .indefinitely, "indefinite pause survives reload")

    let firstDeadline = clock.addingTimeInterval(300)
    check(persistence.pause(until: firstDeadline) == .until(firstDeadline) && persistence.restore() == .until(firstDeadline), "timed pause stores its absolute deadline")
    clock = clock.addingTimeInterval(120)
    check(persistence.restore() == .until(firstDeadline), "restart before deadline does not extend timed pause")

    let replacementDeadline = clock.addingTimeInterval(900)
    check(persistence.pause(for: 900) == .until(replacementDeadline) && persistence.restore() == .until(replacementDeadline), "renewing a timed pause replaces the previous deadline")
    check(persistence.pauseIndefinitely() == .indefinitely && persistence.restore() == .indefinitely, "indefinite pause replaces a timed pause")
    check(persistence.pause(until: replacementDeadline) == .until(replacementDeadline), "timed pause replaces an indefinite pause")

    clock = replacementDeadline
    check(persistence.restore() == .expired && persistence.restore() == .expired, "expired pause remains observable until the Store freezes the current clipboard revision")
    check(!persistence.restore().isPaused, "expired pause restores an active recording state")
    persistence.clear()
    check(persistence.restore() == .recording, "expired pause is cleared after the Store samples the resume boundary")
    _ = persistence.pauseIndefinitely()
    persistence.clear()
    check(persistence.restore() == .recording, "manual resume clears every persisted pause mode")

    var controlReasons = RecordingPauseReasons()
    check(controlReasons.control == RecordingPauseControl(action: .pause, status: "正在记录剪贴板", buttonTitle: "暂停记录"), "recording state offers pause")
    controlReasons.beginTemporaryPause()
    check(controlReasons.control == RecordingPauseControl(action: .unavailable, status: "正在处理数据，暂时暂停记录", buttonTitle: "暂停记录"), "temporary work cannot become a persisted user pause")
    controlReasons.setUserPaused(true)
    check(controlReasons.control.action == .resume && controlReasons.control.buttonTitle == "继续记录", "explicit user pause remains resumable during temporary work")
    controlReasons.setSaveFailure("disk full")
    check(controlReasons.control == RecordingPauseControl(action: .retrySave, status: "历史保存失败：disk full", buttonTitle: "重试保存"), "save failure offers its own recovery action")
    controlReasons.setLoadFailure("missing attachment")
    check(controlReasons.control == RecordingPauseControl(action: .retryLoad, status: "历史读取失败：missing attachment", buttonTitle: "重试读取"), "load failure takes priority over save failure")
    controlReasons.setLoadFailure(nil)
    check(controlReasons.control.action == .retrySave, "clearing a load failure does not clear a save failure")

    var reasons = RecordingPauseReasons()
    reasons.beginTemporaryPause()
    reasons.setUserPaused(true)
    reasons.setUserPaused(false)
    check(reasons.isPaused && reasons.temporaryPauseCount == 1, "resuming user pause does not clear a temporary pause")
    reasons.endTemporaryPause()
    reasons.setLoadFailure("broken history")
    reasons.setUserPaused(true)
    reasons.setUserPaused(false)
    check(reasons.isPaused && reasons.loadFailure != nil, "resuming user pause does not clear a load failure")
    reasons.setRecordingAccepted(false)
    reasons.setLoadFailure(nil)
    check(reasons.control.action == .enable, "first-use consent has a distinct enable action")
    reasons.setSaveFailure("read-only")
    reasons.setRecordingAccepted(true)
    check(reasons.control.action == .retrySave, "accepting recording does not clear a storage failure")
    reasons.setSaveFailure(nil)
    check(reasons.control.action == .pause, "successful save recovery clears only the write failure")

    var pausedDuringRecovery = RecordingPauseReasons()
    pausedDuringRecovery.setUserPaused(true)
    pausedDuringRecovery.setSaveFailure("read-only")
    pausedDuringRecovery.setSaveFailure(nil)
    check(pausedDuringRecovery.control.action == .resume && pausedDuringRecovery.userPaused, "save recovery preserves an explicit user pause")

    var timerSchedule = RecordingPauseTimerSchedule()
    let timerNow = Date(timeIntervalSince1970: 1_900_000_000)
    let firstToken = timerSchedule.replace(with: timerNow.addingTimeInterval(30))
    check(timerSchedule.remainingDelay(for: firstToken, now: timerNow) == 30, "current timed pause waits until its absolute deadline")
    let replacementToken = timerSchedule.replace(with: timerNow.addingTimeInterval(60))
    check(timerSchedule.remainingDelay(for: firstToken, now: timerNow) == nil, "replaced timer callback cannot resume a newer pause")
    check(timerSchedule.remainingDelay(for: replacementToken, now: timerNow.addingTimeInterval(60)) == 0, "current timer becomes eligible at its deadline")
    timerSchedule.cancel()
    check(timerSchedule.remainingDelay(for: replacementToken, now: timerNow.addingTimeInterval(90)) == nil, "cancelled timer callback cannot resume recording later")

    func setClipboard(_ text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    func isolatedStore(_ pasteboard: NSPasteboard) -> Store {
        let store = Store(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("OpenPaste-pause-capture-\(UUID())"),
            ephemeral: true
        )
        store.pauseBoundaryPasteboard = { pasteboard }
        return store
    }

    let startupPasteboard = NSPasteboard.withUniqueName()
    defer { startupPasteboard.releaseGlobally() }
    setClipboard("current clipboard at normal startup", on: startupPasteboard)
    let startupStore = isolatedStore(startupPasteboard)
    startupStore.capture(force: true, pasteboard: startupPasteboard)
    check(startupStore.archive.clips.map(\.text) == ["current clipboard at normal startup"], "normal startup still captures the current clipboard")

    let consentPasteboard = NSPasteboard.withUniqueName()
    defer { consentPasteboard.releaseGlobally() }
    setClipboard("current clipboard at first consent", on: consentPasteboard)
    let consentStore = isolatedStore(consentPasteboard)
    consentStore.setRecordingAccepted(false)
    consentStore.capture(force: true, pasteboard: consentPasteboard)
    check(consentStore.archive.clips.isEmpty, "declined consent blocks forced capture")
    consentStore.setRecordingAccepted(true)
    consentStore.capture(force: true, pasteboard: consentPasteboard)
    check(consentStore.archive.clips.map(\.text) == ["current clipboard at first consent"], "first consent still captures the current clipboard")

    let manualPasteboard = NSPasteboard.withUniqueName()
    defer { manualPasteboard.releaseGlobally() }
    setClipboard("before manual pause", on: manualPasteboard)
    let manualStore = isolatedStore(manualPasteboard)
    manualStore.capture(force: true, pasteboard: manualPasteboard)
    manualStore.setUserPaused(true)
    setClipboard("copied during manual pause", on: manualPasteboard)
    manualStore.capture(force: true, pasteboard: manualPasteboard)
    manualStore.setUserPaused(false)
    manualStore.capture(force: true, pasteboard: manualPasteboard)
    check(manualStore.archive.clips.map(\.text) == ["before manual pause"], "manual resume and show-shelf force do not backfill the clipboard copied while paused")
    setClipboard("copied after manual resume", on: manualPasteboard)
    manualStore.capture(pasteboard: manualPasteboard)
    check(manualStore.archive.clips.first?.text == "copied after manual resume", "the first new copy after manual resume is captured")

    let timerPasteboard = NSPasteboard.withUniqueName()
    defer { timerPasteboard.releaseGlobally() }
    let timerStore = isolatedStore(timerPasteboard)
    timerStore.setUserPaused(true)
    setClipboard("copied during timed pause", on: timerPasteboard)
    timerStore.setUserPaused(false)
    timerStore.capture(force: true, pasteboard: timerPasteboard)
    check(timerStore.archive.clips.isEmpty, "timer resume does not backfill the clipboard copied while paused")
    setClipboard("copied after timer resume", on: timerPasteboard)
    timerStore.capture(pasteboard: timerPasteboard)
    check(timerStore.archive.clips.map(\.text) == ["copied after timer resume"], "timer resume captures only a later clipboard revision")

    let restartPasteboard = NSPasteboard.withUniqueName()
    defer { restartPasteboard.releaseGlobally() }
    let restartStore = isolatedStore(restartPasteboard)
    let restartDeadline = clock.addingTimeInterval(60)
    _ = persistence.pause(until: restartDeadline)
    restartStore.setUserPaused(persistence.restore().isPaused)
    setClipboard("copied before a restarted timer expires", on: restartPasteboard)
    restartStore.capture(force: true, pasteboard: restartPasteboard)
    check(restartStore.archive.clips.isEmpty, "restart before a timed-pause deadline remains paused")
    restartStore.setUserPaused(false)
    restartStore.capture(force: true, pasteboard: restartPasteboard)
    check(restartStore.archive.clips.isEmpty, "a restarted timer freezes its clipboard revision when it expires")

    let expiredPasteboard = NSPasteboard.withUniqueName()
    defer { expiredPasteboard.releaseGlobally() }
    setClipboard("copied while the app was closed and paused", on: expiredPasteboard)
    let expiredStore = isolatedStore(expiredPasteboard)
    clock = restartDeadline
    check(persistence.restore() == .expired, "restart after a timed-pause deadline preserves the expired transition")
    expiredStore.notePersistedPauseExpired()
    persistence.clear()
    expiredStore.capture(force: true, pasteboard: expiredPasteboard)
    check(expiredStore.archive.clips.isEmpty, "expired restart does not backfill the clipboard copied while paused")
    setClipboard("copied after expired restart", on: expiredPasteboard)
    expiredStore.capture(pasteboard: expiredPasteboard)
    check(expiredStore.archive.clips.map(\.text) == ["copied after expired restart"], "expired restart captures the next clipboard revision")

    let expiredOverlapPasteboard = NSPasteboard.withUniqueName()
    defer { expiredOverlapPasteboard.releaseGlobally() }
    let expiredOverlapStore = isolatedStore(expiredOverlapPasteboard)
    expiredOverlapStore.setRecordingSaveFailure("fixture")
    expiredOverlapStore.notePersistedPauseExpired()
    setClipboard("copied while expired restart still has a storage pause", on: expiredOverlapPasteboard)
    expiredOverlapStore.setRecordingSaveFailure(nil)
    expiredOverlapStore.capture(force: true, pasteboard: expiredOverlapPasteboard)
    check(expiredOverlapStore.archive.clips.isEmpty, "expired restart waits for overlapping storage recovery before freezing the revision")
    setClipboard("copied after expired restart storage recovery", on: expiredOverlapPasteboard)
    expiredOverlapStore.capture(pasteboard: expiredOverlapPasteboard)
    check(expiredOverlapStore.archive.clips.map(\.text) == ["copied after expired restart storage recovery"], "expired restart with storage recovery captures only a later revision")

    let overlapPasteboard = NSPasteboard.withUniqueName()
    defer { overlapPasteboard.releaseGlobally() }
    let overlapStore = isolatedStore(overlapPasteboard)
    overlapStore.setUserPaused(true)
    overlapStore.setRecordingSaveFailure("fixture")
    setClipboard("copied during user and storage pause", on: overlapPasteboard)
    overlapStore.setUserPaused(false)
    setClipboard("copied during remaining storage pause", on: overlapPasteboard)
    overlapStore.setRecordingSaveFailure(nil)
    overlapStore.capture(force: true, pasteboard: overlapPasteboard)
    check(overlapStore.archive.clips.isEmpty, "storage recovery freezes the latest revision after an overlapping user pause")
    overlapStore.beginTemporaryPause()
    overlapStore.setUserPaused(true)
    overlapStore.setUserPaused(false)
    setClipboard("copied during remaining temporary pause", on: overlapPasteboard)
    overlapStore.endTemporaryPause()
    overlapStore.capture(force: true, pasteboard: overlapPasteboard)
    check(overlapStore.archive.clips.isEmpty, "temporary-work recovery freezes the latest revision after an overlapping user pause")
    setClipboard("copied after all overlapping pauses", on: overlapPasteboard)
    overlapStore.capture(pasteboard: overlapPasteboard)
    check(overlapStore.archive.clips.map(\.text) == ["copied after all overlapping pauses"], "capture resumes after every overlapping pause reason clears")

    print("Recording pause: \(checks) checks passed")
}
