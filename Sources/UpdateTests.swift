import Foundation

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
    print("Update checks: \(count) tests passed")
}
