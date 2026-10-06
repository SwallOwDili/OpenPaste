import Foundation
import Combine

struct ReleaseVersion: Comparable {
    let numbers: [Int]
    let suffix: [String]
    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        guard text.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: "-", maxSplits: 1)
        let parsed = parts[0].split(separator: ".").compactMap { Int($0) }
        guard parsed.count == 3 else { return nil }
        numbers = parsed
        suffix = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.suffix.isEmpty { return false }
        if rhs.suffix.isEmpty { return true }
        for (a, b) in zip(lhs.suffix, rhs.suffix) where a != b {
            if let x = Int(a), let y = Int(b) { return x < y }
            if Int(a) != nil { return true }
            if Int(b) != nil { return false }
            return a < b
        }
        return lhs.suffix.count < rhs.suffix.count
    }
}
struct GitHubRelease: Codable {
    struct Asset: Codable { let name: String; let state: String }
    let tag_name: String
    let html_url: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var pageURL: URL? {
        guard let url = URL(string: html_url), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/SwallOwDili/OpenPaste/releases/tag/\(tag_name)" else { return nil }
        return url
    }
    func isNewer(than current: String) -> Bool {
        guard !draft, !prerelease, let latest = ReleaseVersion(tag_name), latest.suffix.isEmpty,
              pageURL != nil else { return false }
        if let installed = ReleaseVersion(current) { return installed < latest }
        return current == "draft" || current.range(of: #"^.+-[0-9a-f]{8}$"#, options: .regularExpression) != nil
    }
    var hasInstaller: Bool { assets.contains { $0.state == "uploaded" && $0.name.hasPrefix("OpenPaste-") && $0.name.hasSuffix(".zip") } }
}
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let aboutNotification = Notification.Name("OpenPasteShowAbout")
    @Published var automatic: Bool { didSet {
        defaults.set(automatic, forKey: "automaticUpdateChecks")
        if automatic { checkIfDue() }
    } }
    @Published private(set) var checking = false
    @Published private(set) var release: GitHubRelease?
    @Published private(set) var message = "尚未检查更新"
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private let current: String
    private let session: URLSession
    private var timer: Timer?
    private var lastAttempt: Date?
    private var manualPending = false
    var available: GitHubRelease? { release?.version == defaults.string(forKey: "skippedUpdateVersion") ? nil : release }
    var menuTitle: String { checking ? "正在检查更新…" : available.map { "发现新版 \($0.version)…" } ?? "检查更新…" }
    init(defaults: UserDefaults = .standard, current: String? = nil, session: URLSession? = nil) {
        self.defaults = defaults
        self.current = current ?? Bundle.main.object(forInfoDictionaryKey: "OpenPasteReleaseVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        automatic = defaults.bool(forKey: "automaticUpdateChecks")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        self.session = session ?? URLSession(configuration: config)
        lastAttempt = defaults.object(forKey: "updateLastAttempt") as? Date
        if let data = defaults.data(forKey: "cachedGitHubRelease"), let cached = try? JSONDecoder().decode(GitHubRelease.self, from: data), cached.isNewer(than: self.current), cached.hasInstaller {
            release = cached
            message = "发现新版 \(cached.version)"
        }
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        checkIfDue()
    }
    func checkIfDue(now: Date = Date()) {
        guard automatic, lastAttempt.map({ now.timeIntervalSince($0) >= 86400 }) ?? true else { return }
        check(manual: false)
    }
    func skip() {
        guard let release = release else { return }
        defaults.set(release.version, forKey: "skippedUpdateVersion")
        message = "已跳过 \(release.version)，可手动检查重新查看"
        onChange?()
    }
    func check(manual: Bool = true) {
        manualPending = manualPending || manual
        guard !checking else { return }
        checking = true
        if manual { message = "正在检查更新…" }
        onChange?()
        lastAttempt = Date()
        defaults.set(lastAttempt, forKey: "updateLastAttempt")
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/SwallOwDili/OpenPaste/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenPaste-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let manual = self.manualPending
                self.manualPending = false
                self.checking = false
                defer { self.onChange?() }
                guard error == nil, let http = response as? HTTPURLResponse else { if manual { self.message = "检查失败，请检查网络后重试" }; return }
                if http.statusCode == 404 { self.release = nil; self.defaults.removeObject(forKey: "cachedGitHubRelease"); self.message = "暂未发布正式版本"; return }
                guard http.statusCode == 200 else { if manual { self.message = http.statusCode == 403 || http.statusCode == 429 ? "GitHub 请求受限，请稍后重试" : "检查失败（HTTP \(http.statusCode)）" }; return }
                guard let data = data, data.count <= 2_000_000, let latest = try? JSONDecoder().decode(GitHubRelease.self, from: data), ReleaseVersion(latest.tag_name) != nil, latest.pageURL != nil, !latest.draft, !latest.prerelease else { if manual { self.message = "无法识别版本信息，请稍后重试" }; return }
                if latest.isNewer(than: self.current) {
                    guard latest.hasInstaller else { self.message = "新版安装包仍在构建，请稍后检查"; return }
                    self.release = latest
                    self.defaults.set(try? JSONEncoder().encode(latest), forKey: "cachedGitHubRelease")
                    if manual { self.defaults.removeObject(forKey: "skippedUpdateVersion") }
                    self.message = self.available == nil ? "已跳过 \(latest.version)" : "发现新版 \(latest.version)"
                } else {
                    self.release = nil
                    self.defaults.removeObject(forKey: "cachedGitHubRelease")
                    self.message = "已是最新正式版本"
                }
            }
        }.resume()
    }
}
