import AppKit
import Foundation

func runStorageRecoveryTests() {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("OpenPaste-storage-recovery-\(UUID())")
    defer { try? fm.removeItem(at: sandbox) }
    var checks = 0
    func check(_ value: @autoclosure () throws -> Bool, _ label: String) {
        do {
            guard try value() else { print("FAIL: \(label)"); exit(1) }
            checks += 1
        } catch { print("FAIL: \(label): \(error)"); exit(1) }
    }
    func clip(_ text: String) -> Clip {
        Clip(source: "Recovery fixture", sourceID: "test.recovery", kind: "文字", title: text, text: text,
             parts: [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]])
    }
    func archiveHash(_ archive: Archive) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return HistoryStorage.digest(try encoder.encode(archive))
    }
    func drain(_ store: Store) {
        store.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    func wait(_ timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    do {
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let damagedRoot = sandbox.appendingPathComponent("damaged")
        let original = clip("must survive a failed load")
        let survivor = clip("unrelated attachment must remain untouched")
        let manifest = damagedRoot.appendingPathComponent("history.json")
        try HistoryStorage.write(Archive(clips: [original, survivor]), to: manifest)
        let manifestBytes = try Data(contentsOf: manifest)
        let manifestHash = HistoryStorage.digest(manifestBytes)
        let blobID = HistoryStorage.digest(original.parts[0][0].data)
        let blob = damagedRoot.appendingPathComponent("blobs").appendingPathComponent(blobID)
        let blobBytes = try Data(contentsOf: blob)
        let survivorBlob = damagedRoot.appendingPathComponent("blobs").appendingPathComponent(HistoryStorage.digest(survivor.parts[0][0].data))
        let survivorHash = HistoryStorage.digest(try Data(contentsOf: survivorBlob))
        try fm.removeItem(at: blob)

        let damaged = Store(root: damagedRoot)
        check(!damaged.canModifyHistory && damaged.recordingPauseControl.action == .retryLoad, "missing attachment locks history and offers retry read")
        damaged.setRecordingAccepted(true)
        check(damaged.recordingPauseControl.action == .retryLoad, "accepting recording cannot clear a load failure")
        let guardedBoard = Board(name: "must not change", color: "blue")
        var guardedClip = clip("in-memory sentinel"); guardedClip.boards = [guardedBoard.id]
        let guardedUnpinned = clip("unpinned sentinel")
        damaged.archive = Archive(clips: [guardedClip, guardedUnpinned], boards: [guardedBoard])
        let guardedHash = try archiveHash(damaged.archive)
        check(damaged.ingest(clip("blocked create")) == nil, "load failure rejects creation instead of reporting false success")
        check(!damaged.saveContentEdit(.text(NSAttributedString(string: "blocked edit")), to: .existing(guardedClip.id)),
              "load failure makes content editing report failure")
        var importRejected = false
        do { _ = try damaged.applyPasteImport(PasteImportResult()) }
        catch { importRejected = true }
        let manifestAfterRejectedImport = try Data(contentsOf: manifest)
        check(importRejected && HistoryStorage.digest(manifestAfterRejectedImport) == manifestHash,
              "load failure rejects Paste import before changing the original index")
        damaged.addBoard("blocked board")
        damaged.setBoardColor(guardedBoard.id, color: "red")
        damaged.pin(guardedClip, to: guardedBoard.id)
        damaged.recordUse([guardedClip, guardedUnpinned])
        damaged.delete(guardedClip.id)
        damaged.selected = guardedClip.id; damaged.selection = [guardedClip.id]
        damaged.deleteChosen()
        damaged.clearHistory()
        damaged.removeBoard(guardedBoard.id)
        damaged.prune()
        damaged.demo()
        check(try archiveHash(damaged.archive) == guardedHash, "all ordinary history mutations are inert until the original archive loads")
        check(damaged.undoItems.isEmpty, "blocked batch deletion cannot leave a stale undo entry")
        damaged.save()
        drain(damaged)
        check(HistoryStorage.digest(try Data(contentsOf: manifest)) == manifestHash, "ordinary save cannot replace an index that never loaded")
        check(HistoryStorage.digest(try Data(contentsOf: survivorBlob)) == survivorHash, "load failure leaves unrelated attachments untouched")

        try blobBytes.write(to: blob, options: .atomic)
        damaged.setRecordingAccepted(false)
        damaged.retryRecordingStorage()
        check(wait { damaged.canModifyHistory && damaged.archive.clips.map(\.id) == [original.id, survivor.id] && damaged.recordingPauseControl.action == .enable },
              "successful retry read preserves declined consent and returns to enable recording")
        let recoveredHash = try archiveHash(damaged.archive)
        damaged.undoItemChange()
        check(try archiveHash(damaged.archive) == recoveredHash && damaged.undoItems.isEmpty, "undo after recovery cannot restore cached items from the failed-load state")
        damaged.setRecordingAccepted(true)
        check(damaged.recordingPauseControl.action == .pause, "enabling after load recovery resumes the normal recording control")
        check(HistoryStorage.digest(try Data(contentsOf: manifest)) == manifestHash, "successful retry read leaves the original index intact")

        let unreadableSource = sandbox.appendingPathComponent("unreadable-switch-source")
        try fm.createDirectory(at: unreadableSource, withIntermediateDirectories: true)
        let unreadableManifest = unreadableSource.appendingPathComponent("history.json")
        try Data("broken source index".utf8).write(to: unreadableManifest)
        let unreadableHash = HistoryStorage.digest(try Data(contentsOf: unreadableManifest))
        let badTarget = sandbox.appendingPathComponent("unreadable-switch-bad-target")
        try fm.createDirectory(at: badTarget, withIntermediateDirectories: true)
        let badTargetManifest = badTarget.appendingPathComponent("history.json")
        try Data("broken target index".utf8).write(to: badTargetManifest)
        let badTargetHash = HistoryStorage.digest(try Data(contentsOf: badTargetManifest))
        let recoverySwitch = Store(root: unreadableSource)
        let damagedMemoryClip = clip("must not migrate from a failed source load")
        recoverySwitch.archive = Archive(clips: [damagedMemoryClip])
        recoverySwitch.setUserPaused(true)
        recoverySwitch.changeDataDirectory(to: badTarget)
        check(wait { !recoverySwitch.changingDataDirectory }, "bad recovery target finishes with an explicit failure")
        check(recoverySwitch.root.standardizedFileURL == unreadableSource.standardizedFileURL && !recoverySwitch.canModifyHistory && recoverySwitch.archive.clips.map(\.id) == [damagedMemoryClip.id] && recoverySwitch.directoryStatus.hasPrefix("切换失败"),
              "bad recovery target preserves the protected source and reports the failure")
        let unreadableHashAfterFailure = HistoryStorage.digest(try Data(contentsOf: unreadableManifest))
        let badTargetHashAfterFailure = HistoryStorage.digest(try Data(contentsOf: badTargetManifest))
        check(unreadableHashAfterFailure == unreadableHash && badTargetHashAfterFailure == badTargetHash,
              "failed recovery switch changes neither source nor target bytes")

        let goodTarget = sandbox.appendingPathComponent("unreadable-switch-good-target")
        let targetClip = clip("history loaded from recovery target")
        let cacheClip = clip("history loaded from recovery cache")
        let goodTargetManifest = goodTarget.appendingPathComponent("history.json")
        try HistoryStorage.write(Archive(clips: [targetClip]), to: goodTargetManifest)
        let goodTargetHash = HistoryStorage.digest(try Data(contentsOf: goodTargetManifest))
        let recoveryCache = DataDirectory.cacheURL(goodTarget)
        defer { try? fm.removeItem(at: recoveryCache.deletingLastPathComponent()) }
        try DataDirectory.cache(DataDirectory.baseline(Archive(clips: [cacheClip])), root: goodTarget)
        let recoveryCacheHash = HistoryStorage.digest(try Data(contentsOf: recoveryCache))
        recoverySwitch.changeDataDirectory(to: goodTarget)
        check(wait { !recoverySwitch.changingDataDirectory }, "good recovery target completes")
        check(recoverySwitch.root.standardizedFileURL == goodTarget.standardizedFileURL && recoverySwitch.canModifyHistory && Set(recoverySwitch.archive.clips.map(\.id)) == Set([targetClip.id, cacheClip.id]) && !recoverySwitch.archive.clips.contains(where: { $0.id == damagedMemoryClip.id }),
              "load failure switches by reading the target and cache without merging the damaged source archive")
        check(recoverySwitch.recordingPauseControl.action == .resume && recoverySwitch.userPaused,
              "successful recovery switch preserves an explicit user pause")
        let unreadableHashAfterSuccess = HistoryStorage.digest(try Data(contentsOf: unreadableManifest))
        let goodTargetHashAfterSuccess = HistoryStorage.digest(try Data(contentsOf: goodTargetManifest))
        let recoveryCacheHashAfterSuccess = HistoryStorage.digest(try Data(contentsOf: recoveryCache))
        check(unreadableHashAfterSuccess == unreadableHash && goodTargetHashAfterSuccess == goodTargetHash && recoveryCacheHashAfterSuccess == recoveryCacheHash,
              "successful recovery switch does not rewrite source, target, or cache files")

        let secondUnreadableSource = sandbox.appendingPathComponent("unreadable-switch-empty-source")
        try fm.createDirectory(at: secondUnreadableSource, withIntermediateDirectories: true)
        let secondUnreadableManifest = secondUnreadableSource.appendingPathComponent("history.json")
        try Data("another broken source index".utf8).write(to: secondUnreadableManifest)
        let secondUnreadableHash = HistoryStorage.digest(try Data(contentsOf: secondUnreadableManifest))
        let emptyTarget = sandbox.appendingPathComponent("new-empty-target")
        let emptyRecovery = Store(root: secondUnreadableSource)
        emptyRecovery.changeDataDirectory(to: emptyTarget)
        check(wait { !emptyRecovery.changingDataDirectory }, "new empty recovery target completes")
        check(emptyRecovery.root.standardizedFileURL == emptyTarget.standardizedFileURL && emptyRecovery.canModifyHistory && emptyRecovery.archive.clips.isEmpty,
              "an independent nonexistent directory is accepted as an empty recovery target")
        let secondUnreadableHashAfter = HistoryStorage.digest(try Data(contentsOf: secondUnreadableManifest))
        check(!fm.fileExists(atPath: emptyTarget.path) && secondUnreadableHashAfter == secondUnreadableHash,
              "empty recovery switch performs no directory or source write")

        let suiteName = "OpenPaste.storage-recovery.\(UUID().uuidString)"
        guard let isolatedDefaults = UserDefaults(suiteName: suiteName) else { throw PasteImport.failure("无法创建隔离设置域") }
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        let configuredRoot = sandbox.appendingPathComponent("configuration-domain")
        isolatedDefaults.set(configuredRoot.path, forKey: "dataDirectory")
        let standardStorageLimitBefore = UserDefaults.standard.object(forKey: "storageLimitMB").map { String(describing: $0) }
        let configuredStore = Store(defaults: isolatedDefaults)
        configuredStore.storageLimitMB = 333
        configuredStore.installImportedArchive(Archive())
        let standardStorageLimitAfter = UserDefaults.standard.object(forKey: "storageLimitMB").map { String(describing: $0) }
        check(isolatedDefaults.integer(forKey: "storageLimitMB") == 333 && standardStorageLimitAfter == standardStorageLimitBefore,
              "import settings persist only in the Store configuration domain")

        func verifyBusyHistoryBoundary(_ label: String, setBusy: (Store, Bool) -> Void) throws {
            let busyRoot = sandbox.appendingPathComponent("busy-\(label)")
            let board = Board(name: "busy boundary")
            let editClip = clip("edit before \(label)")
            let renameClip = clip("rename before \(label)")
            let pinClip = clip("pin before \(label)")
            let previewText = "https://example.com/\(label)"
            let previewClip = Clip(source: "Recovery fixture", sourceID: "test.recovery", kind: "链接", title: previewText, text: previewText,
                                   parts: [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(previewText.utf8))]])
            try HistoryStorage.write(Archive(clips: [editClip, renameClip, pinClip, previewClip], boards: [board]), to: busyRoot.appendingPathComponent("history.json"))
            let busyStore = Store(root: busyRoot)
            let originalHash = try archiveHash(busyStore.archive)
            setBusy(busyStore, true)
            check(!busyStore.canModifyHistory && !busyStore.hasHistoryLoadFailure, "\(label) busy state blocks mutation without pretending the history load failed")
            check(!busyStore.saveContentEdit(.text(NSAttributedString(string: "blocked edit")), to: .existing(editClip.id)), "\(label) blocks an already-open editor save")
            var blockedRename = renameClip; blockedRename.title = "blocked rename"; blockedRename.userLabel = "blocked rename"
            busyStore.replace(blockedRename, label: "重命名")
            busyStore.pin(pinClip, to: board.id)
            let preview = LinkPreviewResult(title: "blocked preview", subtitle: "example.com", image: nil, coordinate: nil)
            busyStore.applyLinkPreview(preview, to: previewClip)
            check(try archiveHash(busyStore.archive) == originalHash && busyStore.undoItems.isEmpty, "\(label) leaves editor, rename, favorite, and preview mutations unchanged")

            setBusy(busyStore, false)
            check(busyStore.canModifyHistory, "\(label) mutation boundary reopens after the operation")
            check(busyStore.saveContentEdit(.text(NSAttributedString(string: "saved edit")), to: .existing(editClip.id)), "editor save works after \(label)")
            var savedRename = busyStore.archive.clips.first { $0.id == renameClip.id }!; savedRename.title = "saved rename"; savedRename.userLabel = "saved rename"
            busyStore.replace(savedRename, label: "重命名")
            let currentPin = busyStore.archive.clips.first { $0.id == pinClip.id }!
            busyStore.pin(currentPin, to: board.id)
            let currentPreview = busyStore.archive.clips.first { $0.id == previewClip.id }!
            busyStore.applyLinkPreview(LinkPreviewResult(title: "saved preview", subtitle: "example.com", image: nil, coordinate: nil), to: currentPreview)
            drain(busyStore)
            let persisted = try HistoryStorage.read(from: busyRoot.appendingPathComponent("history.json"))
            check(persisted.clips.first { $0.id == editClip.id }?.text == "saved edit" &&
                  persisted.clips.first { $0.id == renameClip.id }?.userLabel == "saved rename" &&
                  persisted.clips.first { $0.id == pinClip.id }?.boards == [board.id] &&
                  persisted.clips.first { $0.id == previewClip.id }?.linkTitle == "saved preview\nexample.com",
                  "editor, rename, favorite, and preview mutations persist after \(label)")
        }
        try verifyBusyHistoryBoundary("directory migration") { $0.changingDataDirectory = $1 }
        try verifyBusyHistoryBoundary("Paste import") { $0.importingPaste = $1 }

        let importBoundaryRoot = sandbox.appendingPathComponent("import-transaction-boundary")
        let beforeImport = clip("history before queued import")
        try HistoryStorage.write(Archive(clips: [beforeImport]), to: importBoundaryRoot.appendingPathComponent("history.json"))
        let importBoundaryStore = Store(root: importBoundaryRoot)
        let persistenceEntered = DispatchSemaphore(value: 0)
        let releasePersistence = DispatchSemaphore(value: 0)
        importBoundaryStore.persistenceQueue.async {
            persistenceEntered.signal()
            releasePersistence.wait()
        }
        persistenceEntered.wait()
        // Queue a pre-transaction save so the transaction boundary must reject it.
        importBoundaryStore.save()
        importBoundaryStore.importingPaste = true
        importBoundaryStore.beginTemporaryPause()
        importBoundaryStore.invalidatePendingStorageCallbacks()
        let importStorageGeneration = importBoundaryStore.storageCallbackGeneration
        let importSnapshot = importBoundaryStore.archive
        let imported = clip("new Paste history")
        var importResult = PasteImportResult()
        importResult.clips = [imported]
        importResult.total = 1
        importResult.storageBytes = imported.byteCount
        let commitFinished = DispatchSemaphore(value: 0)
        var committedArchive: Archive?
        importBoundaryStore.persistenceQueue.async {
            committedArchive = try? PasteImport.commit(importResult, snapshot: importSnapshot, root: importBoundaryRoot).0
            commitFinished.signal()
        }
        let mutationAtImportStart = importBoundaryStore.directoryMutation
        importBoundaryStore.limit = 1
        importBoundaryStore.retentionDays = 1
        importBoundaryStore.save()
        check(importBoundaryStore.directoryMutation == mutationAtImportStart,
              "limit, retention, and direct saves cannot queue an import-era snapshot")
        releasePersistence.signal()
        commitFinished.wait()
        importBoundaryStore.persistenceQueue.sync {}
        let committedOnDisk = try HistoryStorage.read(from: importBoundaryRoot.appendingPathComponent("history.json"))
        check(Set(committedOnDisk.clips.map(\.id)) == Set([beforeImport.id, imported.id]),
              "queued saves on both sides of the import boundary cannot overwrite the committed index")
        check(importBoundaryStore.storageCallbackGeneration == importStorageGeneration && committedArchive != nil,
              "the import result remains current through the guarded commit")
        importBoundaryStore.installImportedArchive(committedArchive!)
        importBoundaryStore.importingPaste = false
        importBoundaryStore.endTemporaryPause()
        importBoundaryStore.save()
        drain(importBoundaryStore)
        let reopenedImport = Store(root: importBoundaryRoot)
        check(Set(reopenedImport.archive.clips.map(\.id)) == Set([beforeImport.id, imported.id]),
              "the post-transaction save reopens with the merged import")

        let interruptedSyncRoot = sandbox.appendingPathComponent("sync-import-without-ui-completion")
        let syncExisting = clip("existing synchronized history")
        let syncImported = clip("import committed before termination")
        let syncBeforeImport = DataDirectory.baseline(Archive(clips: [syncExisting]))
        try fm.createDirectory(at: interruptedSyncRoot, withIntermediateDirectories: true)
        try DataDirectory.write(syncBeforeImport, root: interruptedSyncRoot, device: "existing-device")
        defer { try? fm.removeItem(at: DataDirectory.cacheURL(interruptedSyncRoot).deletingLastPathComponent()) }
        let interruptedSyncStore = Store(root: interruptedSyncRoot, deviceID: "importing-device")
        var interruptedResult = PasteImportResult()
        interruptedResult.clips = [syncImported]
        interruptedResult.total = 1
        interruptedResult.storageBytes = syncImported.byteCount
        let interruptedSnapshot = interruptedSyncStore.archive
        let interruptedBaseline = interruptedSyncStore.syncBaseline
        interruptedSyncStore.persistenceQueue.async {
            do {
                _ = try PasteImport.commit(interruptedResult, snapshot: interruptedSnapshot, root: interruptedSyncRoot,
                                           syncBaseline: interruptedBaseline, syncDevice: interruptedSyncStore.deviceIDForPersistence())
            } catch {
                print("FAIL: synchronized import commit: \(error)")
                exit(1)
            }
        }
        interruptedSyncStore.flush()
        // Deliberately do not install the result in Store: termination can happen
        // after the persistence queue drains but before its main-thread callback.
        let reopenedWithoutCompletion = try DataDirectory.load(interruptedSyncRoot)
        check(Set(reopenedWithoutCompletion.archive.clips.map(\.id)) == Set([syncExisting.id, syncImported.id]),
              "a synchronized import is durable before its UI completion runs")
        let cachedWithoutCompletion = try DataDirectory.cached(interruptedSyncRoot)
        check(Set(cachedWithoutCompletion?.archive.clips.map(\.id) ?? []) == Set([syncExisting.id, syncImported.id]),
              "a synchronized import updates its recovery cache before UI completion")

        var image = clip("image OCR boundary")
        image.kind = "图片"
        let ocrBoundaryRoot = sandbox.appendingPathComponent("ocr-transaction-boundary")
        try HistoryStorage.write(Archive(clips: [image]), to: ocrBoundaryRoot.appendingPathComponent("history.json"))
        let ocrBoundaryStore = Store(root: ocrBoundaryRoot)
        let oldOCRGeneration = ocrBoundaryStore.storageCallbackGeneration
        ocrBoundaryStore.importingPaste = true
        ocrBoundaryStore.invalidatePendingStorageCallbacks()
        check(!ocrBoundaryStore.applyRecognizedText("must be rejected while busy", to: image, storageGeneration: oldOCRGeneration),
              "an OCR callback cannot mutate history while an import is active")
        ocrBoundaryStore.importingPaste = false
        check(!ocrBoundaryStore.applyRecognizedText("must stay rejected after busy", to: image, storageGeneration: oldOCRGeneration),
              "an OCR callback from before the storage boundary stays invalid after import")
        check(ocrBoundaryStore.applyRecognizedText("current OCR", to: image, storageGeneration: ocrBoundaryStore.storageCallbackGeneration),
              "a current OCR result can update history after the boundary reopens")

        let asynchronousRoot = sandbox.appendingPathComponent("asynchronous-initial-load")
        let asynchronouslyLoaded = clip("loaded after the main thread is released")
        let asynchronousStarted = DispatchSemaphore(value: 0)
        let releaseAsynchronousLoad = DispatchSemaphore(value: 0)
        let asynchronousStore = Store(root: asynchronousRoot, loadHistoryAsynchronously: true, initialHistoryLoader: { _ in
            asynchronousStarted.signal()
            releaseAsynchronousLoad.wait()
            return DataDirectory.baseline(Archive(clips: [asynchronouslyLoaded]))
        })
        asynchronousStarted.wait()
        check(asynchronousStore.initialLoading && asynchronousStore.changingDataDirectory && asynchronousStore.paused && !asynchronousStore.canModifyHistory && asynchronousStore.recordingPauseControl.action == .unavailable,
              "asynchronous startup returns with independent loading, recording, and history mutation gates")
        check(asynchronousStore.ingest(clip("must not enter an empty loading archive")) == nil,
              "initial loading rejects capture into the temporary empty archive")
        asynchronousStore.save()
        var asynchronousImportRejected = false
        do { _ = try asynchronousStore.applyPasteImport(PasteImportResult()) }
        catch { asynchronousImportRejected = true }
        let blockedInitialDestination = sandbox.appendingPathComponent("initial-load-migration-must-not-start")
        asynchronousStore.changeDataDirectory(to: blockedInitialDestination)
        check(asynchronousImportRejected && asynchronousStore.root.standardizedFileURL == asynchronousRoot.standardizedFileURL &&
              !fm.fileExists(atPath: asynchronousRoot.appendingPathComponent("history.json").path) && !fm.fileExists(atPath: blockedInitialDestination.path),
              "initial loading cannot save, import, or start a directory migration from the empty archive")
        let normalStartupPasteboard = NSPasteboard.withUniqueName()
        defer { normalStartupPasteboard.releaseGlobally() }
        asynchronousStore.pauseBoundaryPasteboard = { normalStartupPasteboard }
        normalStartupPasteboard.clearContents()
        normalStartupPasteboard.setString("current clipboard at normal async startup", forType: .string)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { releaseAsynchronousLoad.signal() }
        let flushStarted = Date()
        asynchronousStore.flush()
        let flushDuration = Date().timeIntervalSince(flushStarted)
        check(flushDuration < 0.25 && asynchronousStore.initialLoading,
              "termination flush returns promptly instead of waiting for a read-only initial load")
        asynchronousStore.persistenceQueue.sync {}
        check(asynchronousStore.initialLoading && asynchronousStore.archive.clips.isEmpty,
              "explicit queue draining cannot install history before the main completion runs")
        check(wait { !asynchronousStore.initialLoading }, "asynchronous initial load completes on the main thread")
        check(asynchronousStore.archive.clips.map(\.id) == [asynchronouslyLoaded.id] && !asynchronousStore.paused && !asynchronousStore.changingDataDirectory,
              "successful initial load installs the complete snapshot and releases only its loading pause")
        asynchronousStore.capture(force: true, pasteboard: normalStartupPasteboard)
        check(asynchronousStore.archive.clips.contains { $0.text == "current clipboard at normal async startup" },
              "normal asynchronous startup still permits the initial forced clipboard capture")

        let pauseOverlapRoot = sandbox.appendingPathComponent("pause-ending-during-initial-load")
        let pauseOverlapStarted = DispatchSemaphore(value: 0)
        let releasePauseOverlap = DispatchSemaphore(value: 0)
        let pauseOverlapStore = Store(root: pauseOverlapRoot, loadHistoryAsynchronously: true, initialHistoryLoader: { _ in
            pauseOverlapStarted.signal()
            releasePauseOverlap.wait()
            return DataDirectory.baseline(Archive())
        })
        pauseOverlapStarted.wait()
        let pauseOverlapPasteboard = NSPasteboard.withUniqueName()
        defer { pauseOverlapPasteboard.releaseGlobally() }
        pauseOverlapStore.pauseBoundaryPasteboard = { pauseOverlapPasteboard }
        pauseOverlapPasteboard.clearContents()
        pauseOverlapPasteboard.setString("clipboard copied during overlapping user pause", forType: .string)
        pauseOverlapStore.setUserPaused(true)
        pauseOverlapStore.setUserPaused(false)
        check(pauseOverlapStore.paused, "initial loading remains paused after an overlapping user pause expires")
        releasePauseOverlap.signal()
        pauseOverlapStore.flush()
        check(wait { !pauseOverlapStore.initialLoading }, "initial load completes after an overlapping user pause")
        pauseOverlapStore.capture(force: true, pasteboard: pauseOverlapPasteboard)
        check(!pauseOverlapStore.archive.clips.contains { $0.text == "clipboard copied during overlapping user pause" },
              "initial completion cannot force-capture content from a user pause that ended during loading")
        pauseOverlapPasteboard.clearContents()
        pauseOverlapPasteboard.setString("clipboard copied after overlapping pauses ended", forType: .string)
        pauseOverlapStore.capture(pasteboard: pauseOverlapPasteboard)
        check(pauseOverlapStore.archive.clips.contains { $0.text == "clipboard copied after overlapping pauses ended" },
              "new clipboard revisions record after loading and the overlapping user pause end")

        let failedInitialRoot = sandbox.appendingPathComponent("failed-asynchronous-initial-load")
        let protectedInitial = clip("protected disk history after async load failure")
        let failedInitialManifest = failedInitialRoot.appendingPathComponent("history.json")
        try HistoryStorage.write(Archive(clips: [protectedInitial]), to: failedInitialManifest)
        let failedInitialHash = HistoryStorage.digest(try Data(contentsOf: failedInitialManifest))
        let failedInitialStore = Store(root: failedInitialRoot, loadHistoryAsynchronously: true, initialHistoryLoader: { _ in
            throw PasteImport.failure("injected slow-load failure")
        })
        failedInitialStore.start()
        check(wait { !failedInitialStore.initialLoading }, "failed asynchronous initial load completes")
        let failedInitialHashAfterLoad = HistoryStorage.digest(try Data(contentsOf: failedInitialManifest))
        check(!failedInitialStore.canModifyHistory && failedInitialStore.recordingPauseControl.action == .retryLoad && failedInitialStore.archive.clips.isEmpty &&
              failedInitialHashAfterLoad == failedInitialHash,
              "initial load failure preserves disk history and the existing retry-read protection")
        failedInitialStore.start()
        check(failedInitialStore.timer == nil && failedInitialStore.syncTimer == nil,
              "a start request remains deferred while initial history is unreadable")
        failedInitialStore.retryRecordingStorage()
        check(wait { !failedInitialStore.hasHistoryLoadFailure }, "normal retry succeeds after an injected initial load failure")
        check(failedInitialStore.archive.clips.map(\.id) == [protectedInitial.id] && failedInitialStore.timer != nil && failedInitialStore.syncTimer != nil,
              "successful retry installs protected history before fulfilling the deferred start")
        failedInitialStore.timer?.invalidate(); failedInitialStore.timer = nil
        failedInitialStore.syncTimer?.invalidate(); failedInitialStore.syncTimer = nil

        let switchRecoverySource = sandbox.appendingPathComponent("failed-load-switch-source")
        let switchRecoveryProtected = clip("unreadable source stays untouched")
        let switchRecoveryManifest = switchRecoverySource.appendingPathComponent("history.json")
        try HistoryStorage.write(Archive(clips: [switchRecoveryProtected]), to: switchRecoveryManifest)
        let switchRecoverySourceHash = HistoryStorage.digest(try Data(contentsOf: switchRecoveryManifest))
        let switchRecoveryStore = Store(root: switchRecoverySource, loadHistoryAsynchronously: true, initialHistoryLoader: { _ in
            throw PasteImport.failure("injected source read failure")
        })
        switchRecoveryStore.start()
        check(wait { !switchRecoveryStore.initialLoading && switchRecoveryStore.hasHistoryLoadFailure },
              "directory recovery fixture reaches protected failed-load state")
        let readableRecoveryRoot = sandbox.appendingPathComponent("readable-recovery-target")
        let readableRecoveryClip = clip("history from selected readable directory")
        try HistoryStorage.write(Archive(clips: [readableRecoveryClip]), to: readableRecoveryRoot.appendingPathComponent("history.json"))
        switchRecoveryStore.changeDataDirectory(to: readableRecoveryRoot)
        check(wait(8) { !switchRecoveryStore.changingDataDirectory },
              "switching away from an unreadable initial directory completes")
        check(switchRecoveryStore.root.standardizedFileURL == readableRecoveryRoot.standardizedFileURL &&
              switchRecoveryStore.archive.clips.map(\.id) == [readableRecoveryClip.id] &&
              !switchRecoveryStore.hasHistoryLoadFailure && switchRecoveryStore.timer != nil && switchRecoveryStore.syncTimer != nil,
              "a readable replacement installs before deferred recording resumes without capturing failure-period content")
        check(HistoryStorage.digest(try Data(contentsOf: switchRecoveryManifest)) == switchRecoverySourceHash,
              "failed source archive remains byte-for-byte unchanged after directory recovery")
        switchRecoveryStore.timer?.invalidate(); switchRecoveryStore.timer = nil
        switchRecoveryStore.syncTimer?.invalidate(); switchRecoveryStore.syncTimer = nil

        let automaticRecoveryRoot = sandbox.appendingPathComponent("automatic-cloud-read-recovery")
        let automaticallyRecoveredClip = clip("remote history available on retry")
        try DataDirectory.write(DataDirectory.changes(Archive(clips: [automaticallyRecoveredClip]), from: DataDirectory.baseline(Archive())),
                                root: automaticRecoveryRoot, device: "remote")
        let automaticRecoveryManifest = automaticRecoveryRoot.appendingPathComponent("device-remote.json")
        let automaticRecoveryHash = HistoryStorage.digest(try Data(contentsOf: automaticRecoveryManifest))
        let automaticRecoveryStarted = DispatchSemaphore(value: 0)
        let releaseAutomaticRecoveryFailure = DispatchSemaphore(value: 0)
        let automaticRecoveryStore = Store(root: automaticRecoveryRoot, loadHistoryAsynchronously: true, initialHistoryLoader: { _ in
            automaticRecoveryStarted.signal()
            releaseAutomaticRecoveryFailure.wait()
            throw PasteImport.failure("injected cloud placeholder failure")
        })
        automaticRecoveryStarted.wait()
        automaticRecoveryStore.initialDirectoryLoadFailed = true
        automaticRecoveryStore.start()
        check(automaticRecoveryStore.syncTimer == nil && automaticRecoveryStore.timer == nil,
              "initial loading never starts polling or capture timers")
        releaseAutomaticRecoveryFailure.signal()
        check(wait { !automaticRecoveryStore.initialLoading && automaticRecoveryStore.hasHistoryLoadFailure },
              "automatic recovery fixture reaches protected failed-load state")
        check(automaticRecoveryStore.syncTimer != nil && automaticRecoveryStore.timer == nil,
              "cloud load failure starts only its read-recovery timer")
        automaticRecoveryStore.runSyncTimerAction()
        check(wait { !automaticRecoveryStore.hasHistoryLoadFailure },
              "read-recovery timer retries the unavailable synchronized history")
        let automaticRecoveryHashAfterRetry = HistoryStorage.digest(try Data(contentsOf: automaticRecoveryManifest))
        check(automaticRecoveryStore.archive.clips.map(\.id) == [automaticallyRecoveredClip.id] &&
              automaticRecoveryStore.timer != nil && automaticRecoveryStore.syncTimer != nil &&
              automaticRecoveryHashAfterRetry == automaticRecoveryHash,
              "automatic retry reads the remote snapshot without merging or overwriting an empty local archive, then starts capture")
        automaticRecoveryStore.timer?.invalidate(); automaticRecoveryStore.timer = nil
        automaticRecoveryStore.syncTimer?.invalidate(); automaticRecoveryStore.syncTimer = nil

        let staleInitialRoot = sandbox.appendingPathComponent("stale-asynchronous-initial-load")
        let staleInitialStarted = DispatchSemaphore(value: 0)
        let releaseStaleInitial = DispatchSemaphore(value: 0)
        let staleInitialClip = clip("stale initial result")
        let staleInitialStore = Store(root: staleInitialRoot, loadHistoryAsynchronously: true, initialHistoryLoader: { _ in
            staleInitialStarted.signal()
            releaseStaleInitial.wait()
            return DataDirectory.baseline(Archive(clips: [staleInitialClip]))
        })
        staleInitialStarted.wait()
        let replacementInitialRoot = sandbox.appendingPathComponent("replacement-after-initial-load")
        try fm.createDirectory(at: replacementInitialRoot, withIntermediateDirectories: true)
        let replacementInitialClip = clip("replacement generation")
        staleInitialStore.invalidatePendingStorageCallbacks()
        staleInitialStore.root = replacementInitialRoot
        staleInitialStore.archive = Archive(clips: [replacementInitialClip])
        staleInitialStore.initialLoading = false
        staleInitialStore.changingDataDirectory = false
        staleInitialStore.endTemporaryPause()
        staleInitialStore.setRecordingLoadFailure("replacement root remains protected")
        releaseStaleInitial.signal()
        staleInitialStore.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(staleInitialStore.root.standardizedFileURL == replacementInitialRoot.standardizedFileURL && staleInitialStore.archive.clips.map(\.id) == [replacementInitialClip.id] &&
              staleInitialStore.recordingPauseControl.action == .retryLoad && staleInitialStore.recordingPauseControl.status.contains("replacement root remains protected"),
              "a stale initial-load callback cannot install history or clear a newer root generation")

        let staleLoadRoot = sandbox.appendingPathComponent("stale-load")
        let staleLoadedClip = clip("old root archive")
        let staleManifest = staleLoadRoot.appendingPathComponent("history.json")
        try HistoryStorage.write(Archive(clips: [staleLoadedClip]), to: staleManifest)
        let staleBlob = staleLoadRoot.appendingPathComponent("blobs").appendingPathComponent(HistoryStorage.digest(staleLoadedClip.parts[0][0].data))
        let staleBlobBytes = try Data(contentsOf: staleBlob)
        try fm.removeItem(at: staleBlob)
        let staleLoad = Store(root: staleLoadRoot)
        try staleBlobBytes.write(to: staleBlob, options: .atomic)
        staleLoad.retryRecordingStorage()
        staleLoad.persistenceQueue.sync {}
        staleLoad.invalidatePendingStorageCallbacks()
        let replacementRoot = sandbox.appendingPathComponent("replacement-root")
        try fm.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        staleLoad.root = replacementRoot
        let replacementSentinel = clip("new root sentinel")
        staleLoad.archive = Archive(clips: [replacementSentinel])
        staleLoad.setRecordingLoadFailure("new root is still unavailable")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(staleLoad.root.standardizedFileURL == replacementRoot.standardizedFileURL && staleLoad.archive.clips.map(\.id) == [replacementSentinel.id],
              "old retry callback cannot install an archive after root and generation change")
        check(staleLoad.recordingPauseControl.action == .retryLoad && staleLoad.recordingPauseControl.status.contains("new root is still unavailable"),
              "old retry callback cannot clear the new root's load failure")

        let writeRoot = sandbox.appendingPathComponent("write-failure")
        let writer = Store(root: writeRoot)
        writer.setUserPaused(true)
        let blobs = writeRoot.appendingPathComponent("blobs")
        try Data("directory conflict".utf8).write(to: blobs)
        let pending = clip("retained in memory")
        check(writer.ingest(pending) == pending.id, "write failure keeps the newly created item in memory")
        drain(writer)
        check(writer.archive.clips.contains { $0.id == pending.id } && writer.recordingPauseControl.action == .retrySave, "disk write failure pauses with retry save")
        writer.retryRecordingStorage()
        drain(writer)
        check(writer.recordingPauseControl.action == .retrySave, "a consecutive failed retry remains a write failure")
        try fm.removeItem(at: blobs)
        writer.retryRecordingStorage()
        check(wait { writer.recordingPauseControl.action == .resume }, "successful retry clears only the write failure and preserves user pause")
        drain(writer)
        check(try HistoryStorage.read(from: writeRoot.appendingPathComponent("history.json")).clips.contains { $0.id == pending.id }, "recovered save persists the retained in-memory archive")

        let staleRoot = sandbox.appendingPathComponent("stale-save")
        let stale = Store(root: staleRoot)
        let staleBlobs = staleRoot.appendingPathComponent("blobs")
        try Data("directory conflict".utf8).write(to: staleBlobs)
        _ = stale.ingest(clip("old failing generation"))
        stale.persistenceQueue.sync {}
        try fm.removeItem(at: staleBlobs)
        _ = stale.ingest(clip("new successful generation"))
        drain(stale)
        check(stale.recordingPauseControl.action == .pause && !stale.recordingSafetyPaused, "late failure from an older save generation cannot relock recovered storage")

        let switchRoot = sandbox.appendingPathComponent("switch-source")
        let switchedRoot = sandbox.appendingPathComponent("switch-destination")
        let switching = Store(root: switchRoot)
        let switchBlobs = switchRoot.appendingPathComponent("blobs")
        try Data("directory conflict".utf8).write(to: switchBlobs)
        let switchedClip = clip("survives directory switch")
        _ = switching.ingest(switchedClip)
        switching.persistenceQueue.sync {}
        switching.changeDataDirectory(to: switchedRoot)
        check(wait(8) { !switching.changingDataDirectory }, "directory switch completes after an older write callback was queued")
        drain(switching)
        check(switching.root.standardizedFileURL == switchedRoot.standardizedFileURL && !switching.recordingSafetyPaused,
              "callback from the old directory cannot lock the new directory generation")
        check(try HistoryStorage.read(from: switchedRoot.appendingPathComponent("history.json")).clips.contains { $0.id == switchedClip.id },
              "directory switch preserves the in-memory archive")

        print("Storage recovery: \(checks) checks passed")
    } catch { print("FAIL: \(error)"); exit(1) }
}
