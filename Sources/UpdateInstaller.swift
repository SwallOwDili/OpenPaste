import Foundation
import Security
import CryptoKit

enum UpdateInstallError: LocalizedError, Equatable {
    case notInstalledApp
    case translocated
    case adHocSigned
    case unsigned
    case notWritable
    case badAsset
    case download(String)
    case tooLarge
    case checksumMissing
    case checksumMismatch
    case extraction
    case unexpectedContents
    case identityMismatch(String)
    case signatureMismatch
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalledApp: return "当前不是从 .app 运行，无法应用内更新"
        case .translocated: return "应用正在系统的临时路径中运行，请先把 OpenPaste 移到「应用程序」文件夹再更新"
        case .adHocSigned: return "当前版本使用临时签名，无法验证新版来源，请手动下载一次"
        case .unsigned: return "当前版本没有有效签名，无法验证新版来源，请手动下载"
        case .notWritable: return "应用所在目录不可写，无法替换，请手动下载安装"
        case .badAsset: return "更新资源地址无效"
        case .download(let detail): return "下载失败：\(detail)"
        case .tooLarge: return "安装包超过大小上限，已取消"
        case .checksumMissing: return "没有找到有效的 SHA-256 校验文件，已取消"
        case .checksumMismatch: return "SHA-256 校验不一致，已取消，当前版本未改动"
        case .extraction: return "安装包无法解压，已取消，当前版本未改动"
        case .unexpectedContents: return "安装包内容与预期不符，已取消，当前版本未改动"
        case .identityMismatch(let detail): return "新版信息与预期不符（\(detail)），已取消，当前版本未改动"
        case .signatureMismatch: return "新版签名与当前版本不一致，已取消，当前版本未改动"
        case .cancelled: return "已取消更新"
        }
    }
}

/// Pure helpers that do not touch the running app, so they can be unit tested.
enum UpdateVerification {
    static let sizeLimit: Int64 = 150 * 1024 * 1024

    /// Accepts `<64 hex>  <file name>` (shasum) or a bare 64 hex digest.
    static func expectedChecksum(from text: String, fileName: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let digest = fields.first, digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit }) else { continue }
            if fields.count == 1 { return digest.lowercased() }
            let name = fields[1].hasPrefix("*") ? String(fields[1].dropFirst()) : fields[1]
            if fields.count == 2, name == fileName { return digest.lowercased() }
        }
        return nil
    }
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Redirects may only go to HTTPS hosts GitHub serves release assets from.
    static func isAllowedDownloadHost(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
    /// A requirement made only of a code hash is how ad-hoc signing looks; it cannot vouch for a different build.
    static func isCertificateBased(requirement: String) -> Bool {
        requirement.contains("certificate") && !requirement.contains("cdhash")
    }
    static func isTranslocated(_ url: URL) -> Bool { url.path.contains("/AppTranslocation/") }
    /// The extracted archive must hold exactly one application bundle and nothing else (ignoring resource-fork folders).
    static func isExpectedArchiveLayout(_ names: [String], appName: String = "OpenPaste.app") -> Bool {
        let rest = names.filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        return rest == [appName]
    }
}

/// What the next launch should tell the user about an update that was started before quitting.
struct UpdateNotice: Equatable {
    let from: String
    let to: String
    let succeeded: Bool
    private static let key = "pendingUpdateNotice"
    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "OpenPasteReleaseVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    static func recordPending(from: String, to: String, defaults: UserDefaults = AppEnvironment.current.defaults) {
        defaults.set(["from": from, "to": to], forKey: key)
        defaults.synchronize()
    }
    static func clearPending(defaults: UserDefaults = AppEnvironment.current.defaults) { defaults.removeObject(forKey: key) }
    /// Reads and clears the marker. The result depends on which version is actually running now.
    static func consumePending(current: String = installedVersion, defaults: UserDefaults = AppEnvironment.current.defaults) -> UpdateNotice? {
        defer { clearPending(defaults: defaults) }
        guard let pending = defaults.dictionary(forKey: key) as? [String: String], let from = pending["from"], let to = pending["to"] else { return nil }
        return UpdateNotice(from: from, to: to, succeeded: current == to)
    }
}

final class UpdateInstaller: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = UpdateInstaller()
    enum Phase: Equatable { case idle, downloading(Double), verifying, ready, installing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = ""
    var onReady: (() -> Void)?
    private(set) var preparedRelease: GitHubRelease?
    private let bundleURL: URL
    private let fileManager = FileManager.default
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var workDirectory: URL?
    private var stagingDirectory: URL?
    private var stagedApp: URL?
    private var generation = 0

    init(bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL.standardizedFileURL
        super.init()
    }
    var busy: Bool { phase != .idle && phase != .ready }

    // MARK: Eligibility

    static func currentRequirement() -> String? {
        var code: SecCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }
    /// Reasons the running copy cannot be updated in place. nil means it can.
    func blockingReason(requirement: String? = UpdateInstaller.currentRequirement()) -> UpdateInstallError? {
        guard bundleURL.pathExtension == "app" else { return .notInstalledApp }
        guard !UpdateVerification.isTranslocated(bundleURL) else { return .translocated }
        guard let requirement else { return .unsigned }
        guard UpdateVerification.isCertificateBased(requirement: requirement) else { return .adHocSigned }
        guard fileManager.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path),
              fileManager.isDeletableFile(atPath: bundleURL.path) else { return .notWritable }
        return nil
    }

    // MARK: Prepare

    func prepare(_ release: GitHubRelease) {
        guard !busy else { return }
        if let reason = blockingReason() { fail(reason); return }
        guard let zipName = release.installerName, let sumName = release.checksumName,
              let zipURL = release.assetURL(zipName), let sumURL = release.assetURL(sumName) else { fail(.checksumMissing); return }
        discardPrepared()
        generation += 1
        let current = generation
        preparedRelease = release
        phase = .downloading(0); message = "正在下载 \(release.version)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let work = self.fileManager.temporaryDirectory.appendingPathComponent("OpenPaste-update-\(UUID().uuidString)", isDirectory: true)
                try self.fileManager.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                await MainActor.run { self.workDirectory = work }
                let sumFile = try await self.download(sumURL, limit: 4096, to: work.appendingPathComponent("checksum"), generation: current)
                guard let sumText = try? String(contentsOf: sumFile, encoding: .utf8),
                      let expected = UpdateVerification.expectedChecksum(from: sumText, fileName: zipName) else { throw UpdateInstallError.checksumMissing }
                let zipFile = try await self.download(zipURL, limit: UpdateVerification.sizeLimit, to: work.appendingPathComponent(zipName), generation: current)
                try await self.verifyAndStage(zip: zipFile, expected: expected, release: release, generation: current)
                await MainActor.run {
                    guard self.generation == current else { return }
                    self.phase = .ready; self.message = "\(release.version) 已下载并验证，可重启安装"
                    self.onReady?()
                }
            } catch {
                await MainActor.run {
                    guard self.generation == current else { return }
                    self.fail((error as? UpdateInstallError) ?? .download(error.localizedDescription))
                }
            }
        }
    }
    func cancel() {
        generation += 1
        task?.cancel()
        discardPrepared()
        phase = .idle; message = ""
    }
    private func fail(_ error: UpdateInstallError) {
        discardPrepared()
        phase = .idle; message = error.localizedDescription
    }
    private func discardPrepared() {
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: UpdateInstallError.cancelled)
        if let work = workDirectory { try? fileManager.removeItem(at: work) }
        if let staging = stagingDirectory { try? fileManager.removeItem(at: staging) }
        workDirectory = nil; stagingDirectory = nil; stagedApp = nil; preparedRelease = nil
    }
    /// Removes staging folders a crashed run left next to the app. Backups are never touched here.
    func sweepStaleStaging() {
        let parent = bundleURL.deletingLastPathComponent()
        guard bundleURL.pathExtension == "app", stagingDirectory == nil,
              let names = try? fileManager.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(".OpenPaste-update-") {
            try? fileManager.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    // MARK: Download

    private func download(_ url: URL, limit: Int64, to destination: URL, generation current: Int) async throws -> URL {
        guard UpdateVerification.isAllowedDownloadHost(url) else { throw UpdateInstallError.badAsset }
        downloadLimit = limit
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let location: URL = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("OpenPaste-UpdateInstaller", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            self.task = task
            task.resume()
        }
        guard generation == current else { throw UpdateInstallError.cancelled }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: location, to: destination)
        return destination
    }
    private var downloadLimit: Int64 = 0
    private func finishDownload(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > downloadLimit || totalBytesExpectedToWrite > downloadLimit {
            downloadTask.cancel()
            finishDownload(.failure(UpdateInstallError.tooLarge))
            return
        }
        guard totalBytesExpectedToWrite > 0, downloadLimit == UpdateVerification.sizeLimit else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { if case .downloading = self.phase { self.phase = .downloading(fraction) } }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            finishDownload(.failure(UpdateInstallError.download("HTTP \(code)")))
            return
        }
        // The system deletes `location` when this returns, so keep our own copy first.
        let kept = fileManager.temporaryDirectory.appendingPathComponent("OpenPaste-download-\(UUID().uuidString)")
        do { try fileManager.moveItem(at: location, to: kept); finishDownload(.success(kept)) }
        catch { finishDownload(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finishDownload(.failure((error as? UpdateInstallError) ?? UpdateInstallError.download((error as NSError).code == NSURLErrorCancelled ? "已取消" : error.localizedDescription)))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(UpdateVerification.isAllowedDownloadHost(request.url) ? request : nil)
    }

    // MARK: Verify and stage

    private func verifyAndStage(zip: URL, expected: String, release: GitHubRelease, generation current: Int) async throws {
        guard generation == current else { throw UpdateInstallError.cancelled }
        await MainActor.run { self.phase = .verifying; self.message = "正在校验…" }
        guard try UpdateVerification.sha256(of: zip) == expected else { throw UpdateInstallError.checksumMismatch }
        let staging = bundleURL.deletingLastPathComponent().appendingPathComponent(".OpenPaste-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let owned = await MainActor.run { () -> Bool in
            guard self.generation == current else { return false }
            self.stagingDirectory = staging
            return true
        }
        guard owned else { try? fileManager.removeItem(at: staging); throw UpdateInstallError.cancelled }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        ditto.standardOutput = FileHandle.nullDevice; ditto.standardError = FileHandle.nullDevice
        do { try ditto.run(); ditto.waitUntilExit() } catch { throw UpdateInstallError.extraction }
        guard ditto.terminationStatus == 0 else { throw UpdateInstallError.extraction }
        let names = (try? fileManager.contentsOfDirectory(atPath: staging.path)) ?? []
        guard UpdateVerification.isExpectedArchiveLayout(names) else { throw UpdateInstallError.unexpectedContents }
        let app = staging.appendingPathComponent("OpenPaste.app", isDirectory: true)
        try Self.verifyBundle(app, release: release, requirement: Self.currentRequirement(), expectedIdentifier: Bundle.main.bundleIdentifier)
        await MainActor.run { self.stagedApp = app }
    }
    /// Identity and signature checks for an unpacked candidate. The designated requirement of the running app is the trust anchor.
    static func verifyBundle(_ app: URL, release: GitHubRelease, requirement: String?, expectedIdentifier: String?) throws {
        guard let bundle = Bundle(url: app), let identifier = bundle.bundleIdentifier, identifier == expectedIdentifier else {
            throw UpdateInstallError.identityMismatch("bundle id")
        }
        guard bundle.object(forInfoDictionaryKey: "OpenPasteReleaseVersion") as? String == release.version else {
            throw UpdateInstallError.identityMismatch("版本号")
        }
        guard let requirement else { throw UpdateInstallError.unsigned }
        var staticCode: SecStaticCode?
        var parsed: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { throw UpdateInstallError.signatureMismatch }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, parsed) == errSecSuccess else { throw UpdateInstallError.signatureMismatch }
    }

    // MARK: Install

    /// Hands the swap to a detached script that waits for this process to exit, so the running bundle is never modified in place.
    func installAndRelaunch() -> Bool {
        guard phase == .ready, let staged = stagedApp, let work = workDirectory, let staging = stagingDirectory else { return false }
        let script = work.appendingPathComponent("install.sh")
        let body = """
        #!/bin/sh
        APP="$1"; NEW="$2"; PID="$3"; STAGING="$4"; WORK="$5"
        shift 5
        waited=0
        while kill -0 "$PID" 2>/dev/null; do
          waited=$((waited + 1))
          [ "$waited" -gt 600 ] && exit 1
          sleep 0.1
        done
        BACKUP="$(dirname "$APP")/.OpenPaste-previous-$PID"
        if /bin/mv "$APP" "$BACKUP"; then
          if /bin/mv "$NEW" "$APP"; then
            /bin/rm -rf "$BACKUP"
          else
            /bin/mv "$BACKUP" "$APP"
          fi
        fi
        /bin/rm -rf "$STAGING" "$WORK"
        # Relaunch exactly as started, so an isolated acceptance profile never turns into the user's real one.
        # -n starts this path even if another copy with the same bundle id is running; plain open would only activate that copy.
        if [ -n "$OPENPASTE_ACCEPTANCE_ROOT" ]; then
          /usr/bin/open -n --env "OPENPASTE_ACCEPTANCE_ROOT=$OPENPASTE_ACCEPTANCE_ROOT" "$APP" --args "$@"
        else
          /usr/bin/open -n "$APP" --args "$@"
        fi
        """
        UpdateNotice.recordPending(from: UpdateNotice.installedVersion, to: preparedRelease?.version ?? "")
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, bundleURL.path, staged.path, String(ProcessInfo.processInfo.processIdentifier), staging.path, work.path] + CommandLine.arguments.dropFirst()
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            try process.run()
        } catch {
            UpdateNotice.clearPending()
            fail(.download("无法启动安装脚本"))
            return false
        }
        phase = .installing; message = "正在重启安装…"
        return true
    }
}
