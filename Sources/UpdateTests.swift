import AppKit

private final class UpdateMockProtocol: URLProtocol {
    static var status = 200
    static var payload = Data()
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class UpdateSweepFileManager: FileManager, @unchecked Sendable {
    let enumerationStarted = DispatchSemaphore(value: 0)
    let enumerationAllowed = DispatchSemaphore(value: 0)
    let enumerationReturned = DispatchSemaphore(value: 0)
    let enumeratedOnMain = DispatchSemaphore(value: 0)
    let removed = DispatchSemaphore(value: 0)
    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        if Thread.isMainThread { enumeratedOnMain.signal() }
        enumerationStarted.signal()
        _ = enumerationAllowed.wait(timeout: .now() + 3)
        defer { enumerationReturned.signal() }
        return try super.contentsOfDirectory(atPath: path)
    }
    override func removeItem(at URL: URL) throws {
        try super.removeItem(at: URL)
        removed.signal()
    }
}
func runUpdateTests() {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { print("FAIL: \(label)"); exit(1) }
        count += 1; print("PASS: \(label)")
    }
    expect(ReleaseVersion("0.9.0")! < ReleaseVersion("0.10.0")!, "numeric version comparison")
    expect(ReleaseVersion("v1.0.0-beta.2")! < ReleaseVersion("1.0.0-beta.10")!, "numeric prerelease comparison")
    expect(ReleaseVersion("1.0.0-rc.1")! < ReleaseVersion("1.0.0")!, "stable supersedes installed prerelease")
    expect(ReleaseVersion("garbage") == nil, "invalid version rejected")
    func release(_ tag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false, url: String? = nil, assets: Bool = true) -> GitHubRelease {
        GitHubRelease(tag_name: tag, html_url: url ?? "https://github.com/SwallOwDili/OpenPaste/releases/tag/\(tag)", body: "Demo release notes", draft: draft, prerelease: prerelease, assets: assets ? [.init(name: "OpenPaste-1.2.0-macos-universal.zip", state: "uploaded")] : [])
    }
    expect(release().isNewer(than: "draft"), "draft can discover stable release")
    expect(release().isNewer(than: "feature/search-a1b2c3d4"), "branch commit build can discover stable release")
    expect(!release().isNewer(than: "invalid"), "unknown installed version not treated as draft")
    expect(release().isNewer(than: "1.1.0"), "new stable release accepted")
    expect(!release().isNewer(than: "1.2.0"), "same version is not update")
    expect(!release(draft: true).isNewer(than: "1.1.0"), "draft ignored")
    expect(!release(prerelease: true).isNewer(than: "1.1.0"), "prerelease ignored")
    expect(!release(url: "https://example.com/update").isNewer(than: "1.1.0"), "untrusted download page rejected")
    expect(!release(assets: false).hasInstaller, "release without installer held back")
    let suite = "OpenPaste.UpdateTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UpdateMockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let checker = UpdateChecker(defaults: defaults, current: "1.1.0", session: session)
    expect(!checker.automatic, "automatic checks opt in")
    checker.checkIfDue()
    expect(!checker.checking, "disabled automatic check sends no request")
    func check(_ status: Int, _ item: GitHubRelease? = nil, manual: Bool = true) {
        UpdateMockProtocol.status = status
        UpdateMockProtocol.payload = item.flatMap { try? JSONEncoder().encode($0) } ?? Data("invalid".utf8)
        checker.check(manual: manual)
        let deadline = Date().addingTimeInterval(3)
        while checker.checking && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        expect(!checker.checking, "request completes \(status)")
    }
    check(200, release())
    expect(checker.available?.version == "1.2.0", "mock HTTP response produces update")
    checker.skip()
    expect(checker.available == nil, "skip hides notification")
    check(200, release(), manual: false)
    expect(checker.available == nil, "automatic check respects skip")
    check(200, release())
    expect(checker.available != nil, "manual check restores skipped version")
    let restored = UpdateChecker(defaults: defaults, current: "1.1.0", session: session)
    expect(restored.available?.version == "1.2.0", "cached update survives restart")
    let upgraded = UpdateChecker(defaults: defaults, current: "1.2.0", session: session)
    expect(upgraded.available == nil, "installed update removes stale badge")
    check(403)
    expect(checker.message.contains("受限"), "rate limit reported manually")
    let before = checker.message
    check(500, manual: false)
    expect(checker.message == before, "automatic error stays silent")
    check(200)
    expect(checker.message.contains("无法识别"), "malformed response reported")
    check(404)
    expect(checker.release == nil && checker.message.contains("暂未发布"), "missing release handled")
    check(200, release(assets: false))
    expect(checker.available == nil && checker.message.contains("仍在构建"), "published release waits for uploaded installer")
    check(200, release("v1.0.0"))
    expect(checker.available == nil && checker.message.contains("最新"), "older release never downgrades")
    let requestCount = UpdateMockProtocol.requests
    checker.automatic = true
    checker.checkIfDue()
    expect(UpdateMockProtocol.requests == requestCount && !checker.checking, "24 hour throttle includes manual attempt")
    // Prerelease opt-in
    func rc(_ tag: String, draft: Bool = false) -> GitHubRelease {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return GitHubRelease(tag_name: tag, html_url: "https://github.com/SwallOwDili/OpenPaste/releases/tag/\(tag)", body: nil, draft: draft, prerelease: tag.contains("-"), assets: [.init(name: "OpenPaste-\(version)-macos-universal.zip", state: "uploaded"), .init(name: "OpenPaste-\(version)-macos-universal.sha256", state: "uploaded")])
    }
    expect(rc("v0.0.4-rc1").isNewer(than: "0.0.3", includePrerelease: true), "prerelease offered when opted in")
    expect(!rc("v0.0.4-rc1").isNewer(than: "0.0.3"), "prerelease hidden by default")
    expect(rc("v0.0.4-rc2").isNewer(than: "0.0.4-rc1", includePrerelease: true), "newer rc replaces older rc")
    expect(!rc("v0.0.4-rc1").isNewer(than: "0.0.4", includePrerelease: true), "stable is never downgraded to rc")
    expect(rc("v0.0.4").isNewer(than: "0.0.4-rc2", includePrerelease: true), "stable supersedes installed rc")
    expect(!rc("v0.0.5-rc1", draft: true).isNewer(than: "0.0.3", includePrerelease: true), "draft ignored even when opted in")
    func listData(_ items: [GitHubRelease]) -> Data { try! JSONEncoder().encode(items) }
    expect(UpdateChecker.newest(in: listData([rc("v0.0.3"), rc("v0.0.4-rc1"), rc("v0.0.4-rc2"), rc("v0.0.5-rc1", draft: true)]), includePrerelease: true)?.tag_name == "v0.0.4-rc2", "list picks newest eligible release")
    expect(UpdateChecker.newest(in: listData([rc("v0.0.4-rc1")]), includePrerelease: true)?.tag_name == "v0.0.4-rc1", "list with only rc offers it")
    expect(UpdateChecker.newest(in: Data("[]".utf8), includePrerelease: true) == nil, "empty list offers nothing")
    expect(UpdateChecker.newest(in: Data("{}".utf8), includePrerelease: false) == nil, "malformed latest rejected")
    let optIn = UpdateChecker(defaults: defaults, current: "0.0.3", session: session)
    UpdateMockProtocol.status = 200
    UpdateMockProtocol.payload = listData([rc("v0.0.3"), rc("v0.0.4-rc1")])
    expect(!optIn.includePrerelease, "prerelease opt-in defaults off")
    optIn.includePrerelease = true
    let optInDeadline = Date().addingTimeInterval(3)
    while (optIn.checking || optIn.available == nil) && Date() < optInDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(optIn.available?.version == "0.0.4-rc1", "opting in discovers rc")
    optIn.includePrerelease = false
    expect(optIn.available == nil, "opting out clears rc offer immediately")
    // Installer addressing
    let target = rc("v0.0.4-rc1")
    expect(target.installerName == "OpenPaste-0.0.4-rc1-macos-universal.zip" && target.checksumName == "OpenPaste-0.0.4-rc1-macos-universal.sha256", "installer and checksum located by exact name")
    expect(target.assetURL("OpenPaste-0.0.4-rc1-macos-universal.zip")?.absoluteString == "https://github.com/SwallOwDili/OpenPaste/releases/download/v0.0.4-rc1/OpenPaste-0.0.4-rc1-macos-universal.zip", "asset URL built from tag and name")
    expect(target.assetURL("../evil.zip") == nil && target.assetURL("OpenPaste-1.0.0-macos-universal.zip/../x") == nil && target.assetURL("other.zip") == nil, "asset names outside the pattern rejected")
    let noChecksum = GitHubRelease(tag_name: target.tag_name, html_url: target.html_url, body: nil, draft: false, prerelease: true, assets: [.init(name: "OpenPaste-0.0.4-rc1-macos-universal.zip", state: "uploaded")])
    expect(noChecksum.checksumName == nil, "missing checksum detected")
    let digest = String(repeating: "ab", count: 32)
    expect(UpdateVerification.expectedChecksum(from: "\(digest)  OpenPaste-x.zip\n", fileName: "OpenPaste-x.zip") == digest, "shasum line parsed")
    expect(UpdateVerification.expectedChecksum(from: digest.uppercased(), fileName: "any.zip") == digest, "bare digest parsed and lowercased")
    expect(UpdateVerification.expectedChecksum(from: "\(digest)  other.zip", fileName: "OpenPaste-x.zip") == nil, "checksum for another file rejected")
    expect(UpdateVerification.expectedChecksum(from: "not a digest", fileName: "x.zip") == nil && UpdateVerification.expectedChecksum(from: "abc  x.zip", fileName: "x.zip") == nil, "malformed checksum rejected")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPasteUpdateTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let abc = scratch.appendingPathComponent("abc.bin"); try! Data("abc".utf8).write(to: abc)
    expect((try? UpdateVerification.sha256(of: abc)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of known content")
    expect(UpdateVerification.isAllowedDownloadHost(URL(string: "https://github.com/a")) && UpdateVerification.isAllowedDownloadHost(URL(string: "https://release-assets.githubusercontent.com/x")), "GitHub hosts allowed")
    expect(!UpdateVerification.isAllowedDownloadHost(URL(string: "http://github.com/a")) && !UpdateVerification.isAllowedDownloadHost(URL(string: "https://evilgithub.com/a")) && !UpdateVerification.isAllowedDownloadHost(URL(string: "https://github.com.evil.example/a")) && !UpdateVerification.isAllowedDownloadHost(URL(string: "https://u:p@github.com/a")), "non-GitHub or insecure hosts refused")
    expect(UpdateVerification.isCertificateBased(requirement: "identifier \"x\" and certificate leaf = H\"ab\"") && !UpdateVerification.isCertificateBased(requirement: "cdhash H\"ab\" or cdhash H\"cd\""), "ad-hoc requirement is not certificate based")
    expect(UpdateVerification.isExpectedArchiveLayout(["OpenPaste.app"]) && UpdateVerification.isExpectedArchiveLayout(["OpenPaste.app", "__MACOSX"]), "single app archive accepted")
    expect(!UpdateVerification.isExpectedArchiveLayout([]) && !UpdateVerification.isExpectedArchiveLayout(["OpenPaste.app", "run.sh"]) && !UpdateVerification.isExpectedArchiveLayout(["Other.app"]), "unexpected archive contents rejected")
    // Eligibility of the running copy
    let appDir = scratch.appendingPathComponent("Apps", isDirectory: true)
    let fakeApp = appDir.appendingPathComponent("OpenPaste.app", isDirectory: true)
    try! FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)
    let signed = "identifier \"io.github.SwallOwDili.OpenPaste\" and certificate leaf = H\"ab\""
    expect(UpdateInstaller(bundleURL: fakeApp).blockingReason(requirement: signed) == nil, "writable certificate-signed app can update")
    expect(UpdateInstaller(bundleURL: fakeApp).blockingReason(requirement: "cdhash H\"ab\"") == .adHocSigned, "ad-hoc app refused")
    expect(UpdateInstaller(bundleURL: fakeApp).blockingReason(requirement: nil) == .unsigned, "unsigned app refused")
    expect(UpdateInstaller(bundleURL: scratch.appendingPathComponent("OpenPaste")).blockingReason(requirement: signed) == .notInstalledApp, "non-bundle run refused")
    expect(UpdateInstaller(bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/OpenPaste.app")).blockingReason(requirement: signed) == .translocated, "translocated app refused")
    let readOnlyDir = scratch.appendingPathComponent("ReadOnly", isDirectory: true)
    let lockedApp = readOnlyDir.appendingPathComponent("OpenPaste.app", isDirectory: true)
    try! FileManager.default.createDirectory(at: lockedApp, withIntermediateDirectories: true)
    try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)
    expect(UpdateInstaller(bundleURL: lockedApp).blockingReason(requirement: signed) == .notWritable, "unwritable parent refused")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDir.path)
    // Startup cleanup must remain responsive while the app's parent directory is unavailable.
    func waitForSweepSignal(_ signal: DispatchSemaphore) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if signal.wait(timeout: .now()) == .success { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }
    let sweepDir = scratch.appendingPathComponent("Sweep", isDirectory: true)
    let sweepApp = sweepDir.appendingPathComponent("OpenPaste.app", isDirectory: true)
    let stale = sweepDir.appendingPathComponent(".OpenPaste-update-stale", isDirectory: true)
    let backup = sweepDir.appendingPathComponent(".OpenPaste-backup-original", isDirectory: true)
    let unrelated = sweepDir.appendingPathComponent("Other.app", isDirectory: true)
    for directory in [sweepApp, stale, backup, unrelated] { try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    let sweepManager = UpdateSweepFileManager()
    let sweepInstaller = UpdateInstaller(bundleURL: sweepApp, fileManager: sweepManager)
    let sweepStarted = Date()
    sweepInstaller.sweepStaleStaging()
    expect(Date().timeIntervalSince(sweepStarted) < 0.2, "staging sweep returns before slow enumeration completes")
    expect(waitForSweepSignal(sweepManager.enumerationStarted), "staging sweep begins directory enumeration")
    expect(sweepManager.enumeratedOnMain.wait(timeout: .now()) == .timedOut, "staging enumeration runs off the main thread")
    let mainResponded = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { mainResponded.signal() }
    expect(waitForSweepSignal(mainResponded), "main queue responds while staging enumeration is blocked")
    expect(FileManager.default.fileExists(atPath: stale.path), "blocked enumeration has not removed staging")
    sweepManager.enumerationAllowed.signal()
    expect(waitForSweepSignal(sweepManager.removed), "staging sweep eventually removes an abandoned directory")
    expect(!FileManager.default.fileExists(atPath: stale.path), "abandoned staging is removed")
    expect(FileManager.default.fileExists(atPath: backup.path) && FileManager.default.fileExists(atPath: unrelated.path), "staging sweep preserves backups and unrelated apps")
    let cancelledStale = sweepDir.appendingPathComponent(".OpenPaste-update-cancelled-sweep", isDirectory: true)
    try! FileManager.default.createDirectory(at: cancelledStale, withIntermediateDirectories: true)
    let cancelledManager = UpdateSweepFileManager()
    let cancelledInstaller = UpdateInstaller(bundleURL: sweepApp, fileManager: cancelledManager)
    cancelledInstaller.sweepStaleStaging()
    expect(waitForSweepSignal(cancelledManager.enumerationStarted), "competing generation test pauses enumeration")
    // cancel and prepare increment the same generation; this exercises the guard without downloading an update.
    cancelledInstaller.cancel()
    cancelledManager.enumerationAllowed.signal()
    expect(waitForSweepSignal(cancelledManager.enumerationReturned), "cancelled sweep enumeration returns")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    expect(cancelledManager.removed.wait(timeout: .now()) == .timedOut && FileManager.default.fileExists(atPath: cancelledStale.path), "generation change safely skips the entire staging sweep")
    // Candidate identity and signature
    func candidate(id: String, version: String) -> URL {
        let app = scratch.appendingPathComponent("Candidate-\(UUID().uuidString).app", isDirectory: true)
        try! FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "OpenPasteReleaseVersion": version, "CFBundleExecutable": "OpenPaste", "CFBundlePackageType": "APPL"]
        try! (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    func verify(_ app: URL, id: String = "io.github.SwallOwDili.OpenPaste") -> UpdateInstallError? {
        do { try UpdateInstaller.verifyBundle(app, release: target, requirement: signed, expectedIdentifier: id); return nil }
        catch { return error as? UpdateInstallError }
    }
    expect(verify(candidate(id: "com.evil.App", version: "0.0.4-rc1")) == .identityMismatch("bundle id"), "foreign bundle id refused")
    expect(verify(candidate(id: "io.github.SwallOwDili.OpenPaste", version: "0.0.9")) == .identityMismatch("版本号"), "version differing from the release refused")
    expect(verify(candidate(id: "io.github.SwallOwDili.OpenPaste", version: "0.0.4-rc1")) == .signatureMismatch, "unsigned candidate refused")
    // Update result notice
    let noticeSuite = "OpenPaste.UpdateNoticeTests.\(UUID().uuidString)"
    let noticeDefaults = UserDefaults(suiteName: noticeSuite)!
    defer { noticeDefaults.removePersistentDomain(forName: noticeSuite) }
    expect(UpdateNotice.consumePending(current: "0.0.4-rc1", defaults: noticeDefaults) == nil, "no notice without an update in flight")
    UpdateNotice.recordPending(from: "0.0.4-rc0", to: "0.0.4-rc1", defaults: noticeDefaults)
    expect(UpdateNotice.consumePending(current: "0.0.4-rc1", defaults: noticeDefaults) == UpdateNotice(from: "0.0.4-rc0", to: "0.0.4-rc1", succeeded: true), "notice reports success when the new version runs")
    expect(UpdateNotice.consumePending(current: "0.0.4-rc1", defaults: noticeDefaults) == nil, "notice shown only once")
    UpdateNotice.recordPending(from: "0.0.4-rc0", to: "0.0.4-rc1", defaults: noticeDefaults)
    expect(UpdateNotice.consumePending(current: "0.0.4-rc0", defaults: noticeDefaults) == UpdateNotice(from: "0.0.4-rc0", to: "0.0.4-rc1", succeeded: false), "notice reports failure when the old version still runs")
    UpdateNotice.recordPending(from: "0.0.4-rc0", to: "0.0.4-rc1", defaults: noticeDefaults)
    UpdateNotice.clearPending(defaults: noticeDefaults)
    expect(UpdateNotice.consumePending(current: "0.0.4-rc1", defaults: noticeDefaults) == nil, "cancelled install leaves no notice")
    // Release notes in the update dialog
    let notesBody = """
    v0.0.7 的预发布版。\r
    \r
    <p align="center">
      <img src="https://example.com/a.jpg" width="880" alt="效果图" />
      <br />
      <sub>效果图说明</sub>
    </p>

    ### 卡片条与选择

    - **方向键放大**：默认关闭，可在 设置 → 通用 中打开（#23）
    - 第二项
      续行
    1. 第一步 `code`

    ![内联图](https://example.com/b.png)
    普通段落 <b>加粗</b> &amp; [链接](https://example.com/x) [脚本](javascript:alert(1))
    <!-- 注释 -->
    ## C# 支持 ##
    ---
    """
    let notesBlocks = ReleaseNotes.blocks(notesBody)
    expect(notesBlocks == [
        .paragraph("v0.0.7 的预发布版。"),
        .heading(3, "卡片条与选择"),
        .bullet("**方向键放大**：默认关闭，可在 设置 → 通用 中打开（#23）"),
        .bullet("第二项 续行"),
        .numbered("1.", "第一步 `code`"),
        .paragraph("普通段落 加粗 & [链接](https://example.com/x) [脚本](javascript:alert(1))"),
        .heading(2, "C# 支持")
    ], "release notes drop picture blocks, captions, comments and tags into headings, items and paragraphs")
    let notesText = ReleaseNotes.attributed(notesBody)
    expect(!notesText.string.contains("<") && !notesText.string.contains("**") && !notesText.string.contains("###")
           && !notesText.string.contains("效果图") && !notesText.string.contains("example.com"),
           "release notes show no markup, pictures or captions")
    expect(notesText.string.contains("•\t方向键放大：默认关闭"), "release note list items get bullets")
    var linkTargets: [String] = []
    var boldText = ""
    notesText.enumerateAttributes(in: NSRange(location: 0, length: notesText.length)) { attributes, range, _ in
        if let link = attributes[.link] as? URL { linkTargets.append(link.absoluteString) }
        if let font = attributes[.font] as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold),
           notesText.attributedSubstring(from: range).string.hasPrefix("方向键放大") { boldText = notesText.attributedSubstring(from: range).string }
    }
    expect(linkTargets == ["https://example.com/x"], "release notes keep web links only")
    expect(boldText == "方向键放大", "release note bold text is styled")
    expect(ReleaseNotes.attributed("").string == "该版本没有提供更新说明。", "empty release notes show a placeholder")
    // Pictures from this repository on GitHub
    let picture = "https://github.com/SwallOwDili/OpenPaste/releases/download/v9.9.9/picture.png"
    let missing = "https://raw.githubusercontent.com/SwallOwDili/OpenPaste/v9.9.9/docs/missing.png"
    for (url, trusted) in [(picture, true), (missing, true),
                           ("https://github.com/evil/OpenPaste/releases/download/v1/x.png", false),
                           ("http://raw.githubusercontent.com/SwallOwDili/OpenPaste/main/x.png", false),
                           ("https://raw.githubusercontent.com/SwallOwDili/OpenPaste/main/x.png?track=1", false),
                           ("https://example.com/SwallOwDili/OpenPaste/x.png", false)] {
        expect(ReleaseNotes.isTrustedImage(URL(string: url)!) == trusted, "release note picture \(trusted ? "accepted" : "refused"): \(url)")
    }
    let pictureBody = """
    开头一句。

    <p align="center">
      <img src="\(picture)" width="880" alt="示意" />
      <br />
      <sub>上：示意　下：图标</sub>
    </p>

    ![](\(missing))

    <p><img src="https://example.com/x.png" /><sub>外部图片说明</sub></p>

    ### 小节
    """
    expect(ReleaseNotes.blocks(pictureBody) == [
        .paragraph("开头一句。"),
        .image(URL(string: picture)!, caption: "上：示意　下：图标"),
        .image(URL(string: missing)!, caption: nil),
        .heading(3, "小节")
    ], "release note pictures from this repository become picture blocks with captions; others are left out")
    expect(!ReleaseNotes.attributed(pictureBody).string.contains("上：示意"), "pictures and captions are left out without a picture width")
    let pictureStorage = NSTextStorage(attributedString: ReleaseNotes.attributed(pictureBody, imageWidth: 400))
    func slotCount() -> Int {
        var slots = Set<ObjectIdentifier>()
        pictureStorage.enumerateAttribute(ReleaseNotes.imageSlotKey, in: NSRange(location: 0, length: pictureStorage.length)) { value, _, _ in
            if let slot = value as? ReleaseNotes.ImageSlot { slots.insert(ObjectIdentifier(slot)) }
        }
        return slots.count
    }
    func attachmentSizes() -> [NSSize] {
        var sizes: [NSSize] = []
        pictureStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: pictureStorage.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { sizes.append(attachment.bounds.size) }
        }
        return sizes
    }
    expect(slotCount() == 2 && attachmentSizes() == [NSSize(width: 400, height: 168), NSSize(width: 400, height: 168)]
           && pictureStorage.string.contains("上：示意　下：图标"), "each picture starts as a full-width placeholder with its caption")
    // A slow server: one picture arrives after 300 ms, the other is missing.
    final class SlowPictureProtocol: URLProtocol {
        static var png = Data()
        static var requestedOnMain = false
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if Thread.isMainThread { Self.requestedOnMain = true }
            let found = request.url?.lastPathComponent == "picture.png"
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                let response = HTTPURLResponse(url: self.request.url!, statusCode: found ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: [:])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: found ? Self.png : Data("not found".utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() {}
    }
    let source = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
    SlowPictureProtocol.png = NSBitmapImageRep(data: source.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let pictureConfig = URLSessionConfiguration.ephemeral
    pictureConfig.protocolClasses = [SlowPictureProtocol.self]
    let loader = ReleaseNoteImageLoader(session: URLSession(configuration: pictureConfig))
    var loaded = false
    let loadStart = Date()
    loader.load(into: pictureStorage, width: 400) { loaded = true }
    let loadCall = Date().timeIntervalSince(loadStart)
    expect(loadCall < 0.1 && !loaded && slotCount() == 2, "loading pictures returns at once and leaves the placeholders while the server is slow")
    let deadline = Date().addingTimeInterval(5)
    while !loaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    expect(loaded, "picture loading finishes")
    expect(attachmentSizes() == [NSSize(width: 200, height: 100)] && slotCount() == 1,
           "a loaded picture replaces its placeholder at its own size, no wider than the notes")
    expect(!pictureStorage.string.contains("\n\n") && pictureStorage.string.contains("上：示意　下：图标") && pictureStorage.string.hasSuffix("小节"),
           "a missing picture leaves no placeholder or empty line; the loaded picture keeps its caption")
    let cancelledStorage = NSTextStorage(attributedString: ReleaseNotes.attributed(pictureBody, imageWidth: 400))
    let cancelled = ReleaseNoteImageLoader(session: URLSession(configuration: pictureConfig))
    var cancelledDone = false
    cancelled.load(into: cancelledStorage, width: 400) { cancelledDone = true }
    cancelled.cancel()
    let cancelDeadline = Date().addingTimeInterval(5)
    while !cancelledDone && Date() < cancelDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    expect(cancelledDone, "cancelling picture loading settles every placeholder")
    print("Update checks: \(count) tests passed")
}
