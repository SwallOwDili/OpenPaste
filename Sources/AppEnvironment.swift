import Foundation

struct AppEnvironment {
    static let acceptanceArgument = "--acceptance-profile"
    static let acceptanceRootVariable = "OPENPASTE_ACCEPTANCE_ROOT"

    let defaults: UserDefaults
    let defaultDataRoot: URL
    let previewCacheRoot: URL
    let acceptanceMode: Bool
    let allowAnalytics: Bool
    let allowPasteDiscovery: Bool
    private let acceptanceRoot: URL?

    static let current: AppEnvironment = {
        do {
            return try resolve()
        } catch {
            fatalError("OpenPaste environment error: \(error.localizedDescription)")
        }
    }()

    static func resolve(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        currentDirectory: URL? = nil
    ) throws -> AppEnvironment {
        let profileIndexes = arguments.indices.filter { arguments[$0] == acceptanceArgument }
        let rawRoot = environment[acceptanceRootVariable]

        if profileIndexes.isEmpty, rawRoot == nil {
            return production(fileManager: fileManager)
        }
        guard profileIndexes.count == 1, let index = profileIndexes.first else {
            throw EnvironmentError.invalidGate("provide exactly one \(acceptanceArgument) UUID")
        }
        guard arguments.indices.contains(index + 1),
              let profile = UUID(uuidString: arguments[index + 1]) else {
            throw EnvironmentError.invalidProfile
        }
        guard let rawRoot, !rawRoot.isEmpty else {
            throw EnvironmentError.invalidGate("\(acceptanceRootVariable) is required with \(acceptanceArgument)")
        }
        guard (rawRoot as NSString).isAbsolutePath else {
            throw EnvironmentError.rootMustBeAbsolute
        }

        let cwd = (currentDirectory ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)).standardizedFileURL
        let acceptanceParent = cwd.appendingPathComponent("build/acceptance", isDirectory: true).standardizedFileURL
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        guard root.deletingLastPathComponent().path == acceptanceParent.path,
              root.lastPathComponent.caseInsensitiveCompare(profile.uuidString) == .orderedSame else {
            throw EnvironmentError.rootOutsideAcceptanceDirectory(expected: acceptanceParent.appendingPathComponent(profile.uuidString).path)
        }

        let productionRoot = productionDataRoot(fileManager: fileManager)
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let mobileDocuments = home.appendingPathComponent("Library/Mobile Documents", isDirectory: true).standardizedFileURL
        guard !pathsOverlap(root, productionRoot),
              root.path != home.path else {
            throw EnvironmentError.productionPathRejected
        }
        guard !isEqualOrDescendant(root, of: mobileDocuments) else {
            throw EnvironmentError.iCloudPathRejected
        }
        if let link = firstSymbolicLink(in: root, fileManager: fileManager) {
            throw EnvironmentError.symbolicLinkRejected(link.path)
        }

        try fileManager.createDirectory(
            at: acceptanceParent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try prepareAcceptanceRoot(root, profile: profile, fileManager: fileManager)

        let normalizedProfile = profile.uuidString.lowercased()
        let suiteName = "io.github.SwallOwDili.OpenPaste.acceptance.\(normalizedProfile)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw EnvironmentError.defaultsSuiteUnavailable(suiteName)
        }
        let bindingKey = "OpenPasteAcceptanceRoot"
        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        if let existingRoot = domain[bindingKey] as? String, existingRoot != root.path {
            throw EnvironmentError.defaultsRootMismatch(existing: existingRoot, requested: root.path)
        }
        if domain[bindingKey] == nil {
            if !domain.isEmpty {
                throw EnvironmentError.unboundDefaultsSuite(suiteName)
            }
            defaults.set(root.path, forKey: bindingKey)
        }

        let resolved = AppEnvironment(
            defaults: defaults,
            defaultDataRoot: root.appendingPathComponent("Application Support/OpenPaste", isDirectory: true),
            previewCacheRoot: root.appendingPathComponent("Caches/OpenPaste/LinkPreviews", isDirectory: true),
            acceptanceMode: true,
            allowAnalytics: false,
            allowPasteDiscovery: false,
            acceptanceRoot: root
        )
        _ = try resolved.validateDataRoot(resolved.defaultDataRoot, fileManager: fileManager)
        _ = try resolved.validateCacheRoot(resolved.previewCacheRoot, fileManager: fileManager)
        if let savedRoot = defaults.string(forKey: "dataDirectory") {
            _ = try resolved.validateDataRoot(
                URL(fileURLWithPath: savedRoot, isDirectory: true),
                fileManager: fileManager
            )
        }
        return resolved
    }

    private static func production(fileManager: FileManager) -> AppEnvironment {
        AppEnvironment(
            defaults: .standard,
            defaultDataRoot: productionDataRoot(fileManager: fileManager),
            previewCacheRoot: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenPaste/LinkPreviews", isDirectory: true),
            acceptanceMode: false,
            allowAnalytics: true,
            allowPasteDiscovery: true,
            acceptanceRoot: nil
        )
    }

    func validateDataRoot(_ candidate: URL, fileManager: FileManager = .default) throws -> URL {
        try validateAcceptancePath(candidate, kind: "data directory", fileManager: fileManager)
    }

    func validateCacheRoot(_ candidate: URL, fileManager: FileManager = .default) throws -> URL {
        try validateAcceptancePath(candidate, kind: "cache directory", fileManager: fileManager)
    }

    private func validateAcceptancePath(
        _ candidate: URL,
        kind: String,
        fileManager: FileManager
    ) throws -> URL {
        guard acceptanceMode, let acceptanceRoot else { return candidate }
        let path = candidate.standardizedFileURL
        guard path.path != acceptanceRoot.path,
              Self.isEqualOrDescendant(path, of: acceptanceRoot) else {
            throw EnvironmentError.managedPathOutsideRoot(
                kind: kind,
                path: path.path,
                root: acceptanceRoot.path
            )
        }
        if let link = Self.firstSymbolicLink(in: path, fileManager: fileManager) {
            throw EnvironmentError.symbolicLinkRejected(link.path)
        }
        return path
    }

    private static func productionDataRoot(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenPaste", isDirectory: true)
    }

    private static func prepareAcceptanceRoot(_ root: URL, profile: UUID, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        let existed = fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
        if existed, !isDirectory.boolValue {
            throw EnvironmentError.rootIsNotDirectory(root.path)
        }
        if !existed {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if let link = firstSymbolicLink(in: root, fileManager: fileManager) {
            throw EnvironmentError.symbolicLinkRejected(link.path)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let marker = root.appendingPathComponent(".openpaste-acceptance-profile", isDirectory: false)
        let expected = markerContents(profile: profile, root: root)
        if fileManager.fileExists(atPath: marker.path) {
            if let link = firstSymbolicLink(in: marker, fileManager: fileManager) {
                throw EnvironmentError.symbolicLinkRejected(link.path)
            }
            let actual = try String(contentsOf: marker, encoding: .utf8)
            guard actual == expected else { throw EnvironmentError.markerMismatch }
            return
        }

        let contents = try fileManager.contentsOfDirectory(atPath: root.path)
        guard contents.isEmpty else { throw EnvironmentError.nonemptyUnmarkedRoot(root.path) }
        try expected.write(to: marker, atomically: true, encoding: .utf8)
    }

    private static func markerContents(profile: UUID, root: URL) -> String {
        "OpenPaste acceptance profile\nprofile=\(profile.uuidString.lowercased())\nroot=\(root.path)\n"
    }

    private static func firstSymbolicLink(in url: URL, fileManager: FileManager) -> URL? {
        var candidate = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            candidate.appendPathComponent(component)
            if (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                return candidate
            }
        }
        return nil
    }

    private static func pathsOverlap(_ first: URL, _ second: URL) -> Bool {
        isEqualOrDescendant(first, of: second) || isEqualOrDescendant(second, of: first)
    }

    private static func isEqualOrDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let path = candidate.standardizedFileURL.path
        let parent = directory.standardizedFileURL.path
        return path == parent || path.hasPrefix(parent + "/")
    }
}

extension AppEnvironment {
    enum EnvironmentError: LocalizedError {
        case invalidGate(String)
        case invalidProfile
        case rootMustBeAbsolute
        case rootOutsideAcceptanceDirectory(expected: String)
        case productionPathRejected
        case iCloudPathRejected
        case symbolicLinkRejected(String)
        case rootIsNotDirectory(String)
        case nonemptyUnmarkedRoot(String)
        case markerMismatch
        case defaultsSuiteUnavailable(String)
        case defaultsRootMismatch(existing: String, requested: String)
        case unboundDefaultsSuite(String)
        case managedPathOutsideRoot(kind: String, path: String, root: String)

        var errorDescription: String? {
            switch self {
            case .invalidGate(let detail): return "Acceptance isolation requires both gates: \(detail)."
            case .invalidProfile: return "Acceptance profile must be a UUID."
            case .rootMustBeAbsolute: return "Acceptance root must be an absolute path."
            case .rootOutsideAcceptanceDirectory(let expected): return "Acceptance root must be the profile directory \(expected)."
            case .productionPathRejected: return "Acceptance root overlaps the production home or data directory."
            case .iCloudPathRejected: return "Acceptance root must not be inside iCloud Drive."
            case .symbolicLinkRejected(let path): return "Acceptance paths must not contain symbolic links: \(path)."
            case .rootIsNotDirectory(let path): return "Acceptance root is not a directory: \(path)."
            case .nonemptyUnmarkedRoot(let path): return "Refusing nonempty acceptance root without a profile marker: \(path)."
            case .markerMismatch: return "Acceptance root marker does not match the requested profile and path."
            case .defaultsSuiteUnavailable(let suite): return "Unable to create acceptance defaults suite \(suite)."
            case .defaultsRootMismatch(let existing, let requested): return "Acceptance defaults are bound to \(existing), not \(requested)."
            case .unboundDefaultsSuite(let suite): return "Refusing existing unbound acceptance defaults suite \(suite)."
            case .managedPathOutsideRoot(let kind, let path, let root): return "Acceptance \(kind) \(path) must stay inside \(root)."
            }
        }
    }
}
