import Foundation
import OSLog

/// Small, local diagnostics for lifecycle and interaction state.
///
/// Callers must use hard-coded event names and only pass boolean, numeric, or
/// fixed reason-code field values. Clipboard contents, preferences, API keys,
/// window titles, paths, and identifiers for other applications must never be
/// passed here.
enum AppDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.SwallOwDili.OpenPaste",
        category: "interaction"
    )
    private static let writer = DispatchQueue(label: "io.github.SwallOwDili.OpenPaste.diagnostics")
    private static let maximumFileSize = 1_048_576
    private static let logFileName = "OpenPaste.log"

    static func record(_ event: String, _ fields: [String: String] = [:]) {
        let message = format(event: event, fields: fields)
        logger.info("\(message, privacy: .public)")
        let directory = defaultLogDirectory(environment: .current)
        writer.async {
            append(message, to: directory, fileManager: .default)
        }
    }

    /// Directory injection for focused tests. Production call sites should use
    /// `record(_:_:)` so acceptance-mode isolation is always applied.
    static func record(
        _ event: String,
        _ fields: [String: String] = [:],
        logDirectory: URL,
        fileManager: FileManager = .default
    ) {
        let message = format(event: event, fields: fields)
        logger.info("\(message, privacy: .public)")
        writer.async {
            append(message, to: logDirectory, fileManager: fileManager)
        }
    }

    /// Lets a focused test wait for the asynchronous file writer without
    /// exposing file I/O to the UI thread.
    static func waitForPendingWrites() {
        writer.sync {}
    }

    static func defaultLogDirectory(
        environment: AppEnvironment,
        fileManager: FileManager = .default
    ) -> URL {
        if environment.acceptanceMode {
            let profileRoot = environment.defaultDataRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return profileRoot.appendingPathComponent("Logs/OpenPaste", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OpenPaste", isDirectory: true)
    }

    private static func format(event: String, fields: [String: String]) -> String {
        var components = ["event=\(safeToken(event, fallback: "invalid-event"))"]
        components.append(contentsOf: fields.keys.sorted().map { key in
            let safeKey = safeToken(key, fallback: "field")
            let safeValue = safeToken(fields[key] ?? "", fallback: "empty")
            return "\(safeKey)=\(safeValue)"
        })
        return components.joined(separator: " ")
    }

    private static func safeToken(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.prefix(80).map { allowed.contains($0) ? Character(String($0)) : "_" }
        let token = String(scalars)
        return token.isEmpty ? fallback : token
    }

    private static func append(_ message: String, to directory: URL, fileManager: FileManager) {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let log = directory.appendingPathComponent(logFileName, isDirectory: false)
            let rotated = directory.appendingPathComponent("\(logFileName).1", isDirectory: false)
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(timestamp) \(message)\n".utf8)
            let currentSize = ((try? fileManager.attributesOfItem(atPath: log.path)[.size]) as? NSNumber)?.intValue ?? 0

            if currentSize > 0, currentSize + data.count > maximumFileSize {
                try? fileManager.removeItem(at: rotated)
                try fileManager.moveItem(at: log, to: rotated)
            }
            if !fileManager.fileExists(atPath: log.path) {
                guard fileManager.createFile(
                    atPath: log.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else { return }
            }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Diagnostics must never block interaction or surface UI errors.
        }
    }
}
