import Foundation
import CryptoKit

struct ImportProgress {
    var phase: String
    var completed: Int
    var total: Int
    var bytes: Int = 0
    var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
}
private struct DiskPart: Codable { let type: String; let blob: String; let size: Int }
private struct DiskClip: Codable { var clip: Clip; let parts: [[DiskPart]] }
private struct DiskArchive: Codable { let version: Int; let clips: [DiskClip]; let boards: [Board]; var sync: SyncIndex? = nil }
final class ImportStaging {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPaste-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func store(_ parts: [[ClipPart]]) throws -> [[ClipPart]] {
        try parts.map { try $0.map { part in
            let id = HistoryStorage.digest(part.data)
            let url = root.appendingPathComponent(id)
            if !FileManager.default.fileExists(atPath: url.path) {
                try part.data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            return ClipPart(type: part.type, data: try Data(contentsOf: url, options: .mappedIfSafe), storageID: id)
        } }
    }
}
enum HistoryStorage {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validID(_ id: String) -> Bool { id.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func freeBytes(at root: URL) throws -> Int {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let value = values.volumeAvailableCapacityForImportantUsage { return Int(clamping: value) }
        return (try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.intValue ?? 0
    }
    static func read(from url: URL, contentRoot: URL? = nil) throws -> Archive {
        try DataDirectory.ready(url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // Older releases stored all clipboard bytes inline; keep that migration path.
        let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard header?["version"] != nil else { return try JSONDecoder().decode(Archive.self, from: data) }
        let disk = try JSONDecoder().decode(DiskArchive.self, from: data)
        guard disk.version == 2 else { throw PasteImport.failure("历史数据版本不受支持") }
        let folder = (contentRoot ?? url.deletingLastPathComponent()).appendingPathComponent("blobs")
        let clips = try disk.clips.map { item -> Clip in
            var clip = item.clip
            clip.parts = try item.parts.map { try $0.map { part in
                guard validID(part.blob) else { throw PasteImport.failure("历史内容路径无效") }
                let path = folder.appendingPathComponent(part.blob)
                try DataDirectory.ready(path)
                guard path.resolvingSymlinksInPath().deletingLastPathComponent() == folder.resolvingSymlinksInPath(),
                      try path.resourceValues(forKeys: [.fileSizeKey]).fileSize == part.size else { throw PasteImport.failure("历史内容文件缺失或损坏") }
                return ClipPart(type: part.type, data: try Data(contentsOf: path, options: .mappedIfSafe), storageID: part.blob)
            } }
            return clip
        }
        return Archive(clips: clips, boards: disk.boards)
    }
    static func syncIndex(from url: URL) throws -> SyncIndex? {
        try JSONDecoder().decode(DiskArchive.self, from: Data(contentsOf: url)).sync
    }
    static func write(_ archive: Archive, to url: URL, phase: String = "保存内容", progress: ((ImportProgress) -> Void)? = nil, sync: SyncIndex? = nil) throws {
        let folder = url.deletingLastPathComponent().appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var written = 0
        var records: [DiskClip] = []
        var lastUpdate = Date.distantPast
        progress?(ImportProgress(phase: phase, completed: 0, total: archive.clips.count))
        for (index, clip) in archive.clips.enumerated() {
            try autoreleasepool {
                let parts = try clip.parts.map { try $0.map { part -> DiskPart in
                    let id = part.storageID.flatMap { validID($0) ? $0 : nil } ?? digest(part.data)
                    let file = folder.appendingPathComponent(id)
                    if FileManager.default.fileExists(atPath: file.path) {
                        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == part.data.count else { throw PasteImport.failure("已有内容文件损坏") }
                    } else {
                        try part.data.write(to: file, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    }
                    written += part.data.count
                    return DiskPart(type: part.type, blob: id, size: part.data.count)
                } }
                var metadata = clip; metadata.parts = []
                records.append(DiskClip(clip: metadata, parts: parts))
            }
            if Date().timeIntervalSince(lastUpdate) > 0.1 || index == archive.clips.count - 1 {
                lastUpdate = Date(); progress?(ImportProgress(phase: phase, completed: index + 1, total: archive.clips.count, bytes: written))
            }
        }
        progress?(ImportProgress(phase: "保存索引", completed: 0, total: 0, bytes: written))
        let data = try JSONEncoder().encode(DiskArchive(version: 2, clips: records, boards: archive.boards, sync: sync))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    // Preserve references in every manifest/backup and the in-memory undo history.
    // Automatic callers must only collect local roots/caches, never shared cloud attachments.
    static func managedManifest(_ name: String) -> Bool {
        name == "history.json" || (["device-", "before-directory-change-", "before-paste-import-", "migration-"].contains { name.hasPrefix($0) } && name.hasSuffix(".json"))
    }
    static func collectUnused(at root: URL, preserving clips: [Clip] = [], now: Date = Date(), grace: TimeInterval = 0,
                              conflicts: (URL) -> [URL] = { (NSFileVersion.unresolvedConflictVersionsOfItem(at: $0) ?? []).map(\.url) }) throws {
        let fm = FileManager.default
        var retained = Set(clips.flatMap(\.parts).flatMap { $0 }.map { $0.storageID ?? digest($0.data) })
        let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        // Placeholder backups matter too: never infer their references from absence.
        for file in files where file.lastPathComponent.hasPrefix(".") && file.lastPathComponent.hasSuffix(".icloud") {
            let name = String(file.lastPathComponent.dropFirst().dropLast(7))
            if managedManifest(name) { throw PasteImport.failure("iCloud 索引或备份未下载，暂停附件清理") }
        }
        func retain(_ file: URL) throws {
            try DataDirectory.ready(file)
            let data = try Data(contentsOf: file)
            if let disk = try? JSONDecoder().decode(DiskArchive.self, from: data) {
                guard disk.version == 2 else { throw PasteImport.failure("不支持的索引版本，停止附件清理") }
                retained.formUnion(disk.clips.flatMap(\.parts).flatMap { $0 }.map(\.blob))
            } else {
                // An unreadable manifest must never be interpreted as an empty history.
                _ = try JSONDecoder().decode(Archive.self, from: data)
            }
        }
        for file in files where managedManifest(file.lastPathComponent) {
            try retain(file)
            for version in conflicts(file) { try retain(version) }
        }
        let folder = root.appendingPathComponent("blobs")
        guard fm.fileExists(atPath: folder.path) else { return }
        for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]) {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard validID(file.lastPathComponent), !retained.contains(file.lastPathComponent), values.isRegularFile == true, values.isSymbolicLink != true,
                  now.timeIntervalSince(values.contentModificationDate ?? now) >= grace else { continue }
            try fm.removeItem(at: file)
        }
    }

}
