import AppKit
import SQLite3
import Compression
import ImageIO

private struct ImportedPasteItem: Decodable { let types: [String]; let dataByType: [String: Data] }
@objc(OpenPasteLegacyImportItem) private final class LegacyPasteItem: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let parts: [ClipPart]
    required init?(coder: NSCoder) {
        guard let types = coder.decodeObject(of: [NSArray.self, NSString.self], forKey: "types") as? [String],
              let data = coder.decodeObject(of: [NSDictionary.self, NSString.self, NSData.self], forKey: "data") as? [String: Data] else { return nil }
        parts = types.compactMap { type in data[type].map { ClipPart(type: type, data: $0) } }
    }
    func encode(with coder: NSCoder) {}
}
struct PasteImportResult {
    var clips: [Clip] = []
    var boards: [Board] = []
    var total = 0
    var unreadable = 0
    var oversized = 0
    var duplicate = 0
    var capacity = 0
    var byteLimit = 200 * 1024 * 1024
    var storageBytes = 0
    var staging: ImportStaging?
    var databases = 0
    var memberships: [String: [UUID]] = [:]
    var summary: String { "读取 \(total) 条；可导入 \(clips.count) 条；重复 \(duplicate) 条；无法读取 \(unreadable) 条；过大 \(oversized) 条；磁盘空间不足 \(capacity) 条。" }
}
enum PasteImport {
    static let maxBytes = 200 * 1024 * 1024
    static var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Library/Application Support/Paste/db.sqlite", "Library/Application Support/com.wiheads.paste/Paste.db", "Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste/db.sqlite", "Library/Containers/com.wiheads.paste/Data/Library/Application Support/com.wiheads.paste/Paste.db"].map { home.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "OpenPaste.PasteImport", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private static func rows(_ db: OpaquePointer, _ sql: String, _ visit: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure("Paste 数据库结构不受支持") }
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { try autoreleasepool { try visit(statement) }; status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw failure("读取 Paste 失败：\(String(cString: sqlite3_errmsg(db)))") }
    }
    private static func text(_ s: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
    private static func blob(_ s: OpaquePointer, _ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(s, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }
    static func payload(_ value: Data, database: URL) throws -> Data {
        guard let marker = value.first else { throw failure("空内容") }
        var data: Data
        if marker == 2 {
            let name = String(data: value.dropFirst().prefix { $0 != 0 }, encoding: .utf8) ?? ""
            guard UUID(uuidString: name) != nil else { throw failure("无效的外置内容引用") }
            let folder = database.deletingLastPathComponent().appendingPathComponent(".\(database.deletingPathExtension().lastPathComponent)_SUPPORT/_EXTERNAL_DATA")
            let url = folder.appendingPathComponent(name)
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.deletingLastPathComponent() == folder.resolvingSymlinksInPath() else { throw failure("无效的外置内容路径") }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256 * 1024 * 1024 else { throw failure("内容过大") }
            data = try Data(contentsOf: url)
        } else if marker == 1 { data = Data(value.dropFirst()) }
        else { throw failure("未知的 Paste 数据格式") }
        if data.starts(with: Data("bplist00".utf8)) || data.first == 91 { return data }
        let algorithm = data.starts(with: Data("bvx".utf8)) ? COMPRESSION_LZFSE : COMPRESSION_ZLIB
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { throw failure("无法初始化解压") }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        try data.withUnsafeBytes { input in
            stream.src_ptr = input.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = data.count
            while true {
                stream.dst_ptr = buffer; stream.dst_size = 65536
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = 65536 - stream.dst_size
                guard output.count + produced <= 256 * 1024 * 1024 else { throw failure("内容解压后超过限制") }
                output.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK, produced > 0 else { throw failure("内容解压失败") }
            }
        }
        return output
    }

    static func decode(_ data: Data) throws -> [[ClipPart]] {
        if data.starts(with: Data("bplist00".utf8)) {
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            if let items = object as? [[String: Any]] {
                return try items.map { item in
                    guard let types = item["types"] as? [String], let values = item["dataByType"] as? [String: Data] else { throw failure("无效的二进制内容列表") }
                    return try types.map { type in guard let bytes = values[type] else { throw failure("内容缺失") }; return ClipPart(type: type, data: bytes) }
                }
            }
            let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
            decoder.requiresSecureCoding = true
            decoder.decodingFailurePolicy = .setErrorAndReturn
            decoder.setClass(LegacyPasteItem.self, forClassName: "PasteCore.PasteboardItem")
            decoder.setClass(LegacyPasteItem.self, forClassName: "Paste.PasteboardItem")
            defer { decoder.finishDecoding() }
            guard let items = decoder.decodeObject(of: [NSArray.self, LegacyPasteItem.self, NSDictionary.self, NSString.self, NSData.self], forKey: NSKeyedArchiveRootObjectKey) as? [LegacyPasteItem], decoder.error == nil else { throw failure("无法解析旧版内容") }
            return items.map(\.parts)
        }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw failure("无效的内容列表") }
        return try items.map { item in
            guard let types = item["types"] as? [String], let values = item["dataByType"] as? [String: String] else { throw failure("无效的剪贴板内容") }
            return try types.map { type in
                guard let encoded = values[type], let bytes = Data(base64Encoded: encoded) else { throw failure("内容编码损坏") }
                return ClipPart(type: type, data: bytes)
            }
        }
    }
    static func canonicalParts(_ parts: [[ClipPart]]) -> [[ClipPart]] {
        // File references and animated images must not be converted into screenshots.
        if parts.flatMap({ $0 }).contains(where: { ["public.file-url", "NSFilenamesPboardType"].contains($0.type) }) { return parts }
        let imageTypes = ["public.gif", "com.compuserve.gif", "public.png", "public.tiff", "public.jpeg", "public.heic", "com.microsoft.bmp"]
        return parts.map { item in
            let candidates = imageTypes.compactMap { type in item.first { $0.type == type } }
            func pixels(_ part: ClipPart) -> Double {
                guard let source = CGImageSourceCreateWithData(part.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
                return Double((props[kCGImagePropertyPixelWidth] as? Int) ?? 0) * Double((props[kCGImagePropertyPixelHeight] as? Int) ?? 0)
            }
            let candidate = candidates.first(where: { ["public.gif", "com.compuserve.gif"].contains($0.type) }) ?? candidates.enumerated().max { a, b in
                let aSize = pixels(a.element), bSize = pixels(b.element)
                return aSize == bSize ? a.offset > b.offset : aSize < bSize
            }?.element
            guard let candidate, let normalized = ImageCapture.normalize(candidate) else { return item }
            return item.filter { !imageTypes.contains($0.type) } + [normalized]
        }
    }
    static func read(existing: Archive, urls: [URL] = candidates, byteLimit: Int? = nil, destination: URL? = nil, progress: ((ImportProgress) -> Void)? = nil) throws -> PasteImportResult {
        guard !urls.isEmpty else { throw failure("未找到 Paste 数据库。请先在这台 Mac 上运行 Paste，或选择数据文件。") }
        var result = PasteImportResult()
        let staging = try ImportStaging(); result.staging = staging
        var seen: [String: String] = [:]
        var storedIDs = Set<String>()
        var usedBytes = 0
        var lastProgress = Date.distantPast
        for (i, old) in existing.clips.enumerated() {
            let parts = canonicalParts(old.parts)
            var clip = old; clip.parts = parts; clip.cachedDigest = nil
            seen[clip.fingerprint] = old.fingerprint
            for part in parts.flatMap({ $0 }) {
                let id = part.storageID ?? HistoryStorage.digest(part.data)
                if storedIDs.insert(id).inserted { usedBytes += part.data.count }
            }
            if Date().timeIntervalSince(lastProgress) > 0.1 || i == existing.clips.count - 1 {
                lastProgress = Date(); progress?(ImportProgress(phase: "核对原有历史", completed: i + 1, total: existing.clips.count, bytes: usedBytes))
            }
        }
        // Staging and final content can coexist. Reserve room for both and retain 1 GB free.
        let available = try HistoryStorage.freeBytes(at: destination ?? FileManager.default.temporaryDirectory)
        result.byteLimit = max(byteLimit ?? (usedBytes + max(0, available - 1024 * 1024 * 1024) / 2), usedBytes)
        var sourceTotal = 0
        for url in urls {
            var connection: OpaquePointer?
            guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = connection else { if let connection { sqlite3_close(connection) }; throw failure("无法读取 Paste 数据库") }
            defer { sqlite3_close(db) }
            var modern = false
            try rows(db, "SELECT name FROM sqlite_master WHERE name='ZITEMENTITY'") { _ in modern = true }
            try rows(db, "SELECT COUNT(*) FROM " + (modern ? "ZITEMENTITY" : "ZSNIPPET")) { sourceTotal += Int(sqlite3_column_int64($0, 0)) }
        }
        progress?(ImportProgress(phase: "解析 Paste", completed: 0, total: sourceTotal, bytes: usedBytes))
        var namedBoards = Dictionary(existing.boards.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        for url in urls {
            var connection: OpaquePointer?
            guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = connection else { if let connection { sqlite3_close(connection) }; throw failure("无法读取 \(url.lastPathComponent)，请检查文件权限") }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 3000)
            try rows(db, "BEGIN", { _ in })
            var modern = false
            try rows(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='ZITEMENTITY'") { _ in modern = true }
            var boardMap: [Int64: UUID] = [:]
            let listSQL = modern ? "SELECT Z_PK,ZNAME,ZIDENTIFIER FROM ZLISTENTITY WHERE ZRAWTYPE=2" : "SELECT Z_PK,ZNAME,ZIDENTIFIER FROM ZSNIPPETLIST WHERE ZIDENTIFIER<>'sharedPasteboardHistory'"
            try rows(db, listSQL) { s in
                let name = text(s, 1).isEmpty ? "Paste 收藏" : text(s, 1)
                let id: UUID
                if let existing = namedBoards[name] { id = existing } else { let board = Board(name: name); result.boards.append(board); namedBoards[name] = board.id; id = board.id }
                boardMap[sqlite3_column_int64(s, 0)] = id
            }
            var memberships: [Int64: [UUID]] = [:]
            if !modern { try rows(db, "SELECT Z_6SNIPPETS,Z_13LISTS FROM Z_6LISTS") { s in if let id = boardMap[sqlite3_column_int64(s, 1)] { memberships[sqlite3_column_int64(s, 0), default: []].append(id) } } }
            let sql = modern ? "SELECT i.Z_PK,i.ZTIMESTAMP,i.ZTITLE,a.ZNAME,a.ZBUNDLEIDENTIFIER,d.ZRAWPASTEBOARDITEMS,i.ZLIST FROM ZITEMENTITY i LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK=i.ZSOURCEAPPLICATION LEFT JOIN ZITEMDATAENTITY d ON d.Z_PK=i.ZDATA ORDER BY i.ZTIMESTAMP DESC" : "SELECT i.Z_PK,i.ZTIMESTAMP,i.ZTITLE,a.ZNAME,a.ZBUNDLEIDENTIFIER,d.ZPASTEBOARDITEMS,0 FROM ZSNIPPET i LEFT JOIN ZAPPLICATION a ON a.Z_PK=i.ZSOURCEAPPLICATION LEFT JOIN ZSNIPPETDATA d ON d.Z_PK=i.ZDATA ORDER BY i.ZTIMESTAMP DESC"
            try rows(db, sql) { s in
                result.total += 1
                defer {
                    if Date().timeIntervalSince(lastProgress) > 0.1 || result.total >= sourceTotal {
                        lastProgress = Date(); progress?(ImportProgress(phase: "解析 Paste", completed: result.total, total: max(sourceTotal, result.total), bytes: usedBytes))
                    }
                }
                let parts: [[ClipPart]]
                do { parts = canonicalParts(try decode(payload(blob(s, 5), database: url))) } catch { result.unreadable += 1; return }
                guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { result.unreadable += 1; return }
                let flat = parts.flatMap { $0 }
                if flat.contains(where: { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].contains($0.type) }) { result.unreadable += 1; return }
                let bytes = flat.reduce(0) { $0 + $1.data.count }
                guard bytes > 0 else { result.unreadable += 1; return }
                guard bytes <= 20 * 1024 * 1024 else { result.oversized += 1; return }
                func string(_ type: String) -> String? { flat.first(where: { $0.type == type }).flatMap { String(data: $0.data, encoding: .utf8) } }
                var content = string("public.utf8-plain-text") ?? string("public.url") ?? ""
                if content.isEmpty, let rtf = flat.first(where: { $0.type == "public.rtf" }) { content = (try? NSAttributedString(data: rtf.data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string ?? "" }
                let file = flat.contains { $0.type == "public.file-url" || $0.type == "NSFilenamesPboardType" }
                let image = flat.contains { ["public.png", "public.jpeg", "public.tiff", "public.gif", "com.compuserve.gif", "public.heic", "com.microsoft.bmp"].contains($0.type) }
                let link = content.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^https?://[^\\s]+$", options: .regularExpression) != nil
                let title = text(s, 2)
                let boards = modern ? boardMap[sqlite3_column_int64(s, 6)].map { [$0] } ?? [] : memberships[sqlite3_column_int64(s, 0)] ?? []
                var clip = Clip(created: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(s, 1)), source: text(s, 3).isEmpty ? "Paste" : text(s, 3), sourceID: text(s, 4), kind: file ? "文件" : image ? "图片" : link ? "链接" : "文字", title: title.isEmpty ? String(content.prefix(100)) : title, text: content, parts: parts, boards: boards)
                clip.cachedDigest = clip.fingerprint
                if let previous = seen[clip.fingerprint] {
                    if let i = result.clips.firstIndex(where: { $0.fingerprint == clip.fingerprint }) { result.clips[i].boards = Array(Set(result.clips[i].boards + boards)) }
                    else if !boards.isEmpty { result.memberships[previous, default: []] += boards }
                    result.duplicate += 1; return
                }
                let ids = flat.map { $0.storageID ?? HistoryStorage.digest($0.data) }
                var newIDs = Set<String>()
                var additional = 0
                for (part, id) in zip(flat, ids) where !storedIDs.contains(id) && newIDs.insert(id).inserted { additional += part.data.count }
                guard usedBytes + additional <= result.byteLimit else { result.capacity += 1; return }
                clip.parts = try staging.store(parts)
                usedBytes += additional; storedIDs.formUnion(newIDs); seen[clip.fingerprint] = clip.fingerprint; result.clips.append(clip)
            }
            result.databases += 1
        }
        result.storageBytes = usedBytes
        progress?(ImportProgress(phase: "解析完成", completed: result.total, total: result.total, bytes: usedBytes))
        return result
    }

}
extension PasteImport {
    static func commit(_ result: PasteImportResult, snapshot: Archive, root: URL, progress: ((ImportProgress) -> Void)? = nil) throws -> (Archive, Int) {
        let backup = root.appendingPathComponent("before-paste-import-\(UUID().uuidString).json")
        // Immutable content files are shared by the current manifest and backups.
        try HistoryStorage.write(snapshot, to: backup, phase: "备份原有历史", progress: progress)
        var merged = snapshot
        var oldIndices = Dictionary(merged.clips.enumerated().map { ($0.element.fingerprint, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for (digest, boards) in result.memberships { if let i = oldIndices[digest] { merged.clips[i].boards = Array(Set(merged.clips[i].boards + boards)) } }
        oldIndices.removeAll()
        for i in merged.clips.indices {
            merged.clips[i].parts = canonicalParts(merged.clips[i].parts)
            merged.clips[i].cachedDigest = nil
            merged.clips[i].cachedDigest = merged.clips[i].fingerprint
        }
        for board in result.boards where !merged.boards.contains(where: { $0.id == board.id }) { merged.boards.append(board) }
        var indices = Dictionary(merged.clips.enumerated().map { ($0.element.fingerprint, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var added = 0
        for clip in result.clips {
            if let i = indices[clip.fingerprint] { merged.clips[i].boards = Array(Set(merged.clips[i].boards + clip.boards)); continue }
            guard !clip.parts.isEmpty else { continue }
            indices[clip.fingerprint] = merged.clips.count; merged.clips.append(clip); added += 1
        }
        merged.clips.sort { $0.created > $1.created }
        let manifest = root.appendingPathComponent("history.json")
        try HistoryStorage.write(merged, to: manifest, phase: "导入内容", progress: progress)
        // Map immutable files rather than retaining every imported image in memory.
        merged = try HistoryStorage.read(from: manifest)
        progress?(ImportProgress(phase: "导入完成", completed: merged.clips.count, total: merged.clips.count, bytes: result.storageBytes))
        return (merged, added)
    }
}
extension Store {
    func installImportedArchive(_ merged: Archive) {
        applyingImport = true
        defer { applyingImport = false }
        let bytes = merged.clips.reduce(0) { $0 + $1.byteCount }
        storageLimitMB = max(storageLimitMB, (bytes + 64 * 1024 * 1024 + 1048575) / 1048576)
        if usePreferences { UserDefaults.standard.set(storageLimitMB, forKey: "storageLimitMB") }
        if limit != 0 { limit = max(limit, merged.clips.filter { $0.boards.isEmpty }.count) }
        archive = merged
        if DataDirectory.usesSync(root) { save() }
    }
    @discardableResult func applyPasteImport(_ result: PasteImportResult) throws -> Int {
        flush()
        let (merged, added) = try PasteImport.commit(result, snapshot: archive, root: root)
        installImportedArchive(merged)
        return added
    }
}
