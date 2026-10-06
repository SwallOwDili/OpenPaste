import AppKit
import Carbon
import SQLite3
import Compression
import ImageIO
func runTests() {
    var passed = 0
    func check(_ ok: @autoclosure () -> Bool, _ name: String) { if !ok() { print("FAIL: \(name)"); exit(1) }; passed += 1; print("PASS: \(name)") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPaste-test-\(UUID())")
    let store = Store(root: root)
    defer { store.flush(); try? FileManager.default.removeItem(at: root) }
    func clip(_ text: String) -> Clip { Clip(source: "Test", sourceID: "test", kind: "文字", title: text, text: text, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]]) }
    store.ingest(clip("你好 Swift")); store.ingest(clip("Second"))
    check(store.archive.clips.count == 2, "capture and order")
    let id = store.archive.clips[1].id
    store.addBoard("常用"); let b = store.archive.boards[0].id; store.pin(store.archive.clips[1], to: b)
    store.ingest(clip("你好 Swift"))
    check(store.archive.clips.count == 2 && store.archive.clips[0].id == id && store.archive.clips[0].boards == [b], "dedup preserves identity and pin")
    store.query = "SWIFT"; check(store.filtered.count == 1, "case insensitive search")
    store.query = ""; store.board = b; check(store.filtered.count == 1, "board filter")
    store.flush()
    let loaded = Store(root: root); check(loaded.archive.clips.count == 2 && loaded.archive.boards.count == 1, "disk round trip")
    let file = root.appendingPathComponent("history.json")
    let attrs = try! FileManager.default.attributesOfItem(atPath: file.path)
    check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private file permissions")
    store.clearHistory(); check(store.archive.clips.count == 1, "clear keeps pinned clips")
    store.removeBoard(b); check(store.archive.clips[0].boards.isEmpty, "delete board retains item")
    store.limit = 500
    for n in 0..<505 { store.archive.clips.append(clip("limit-\(n)")) }; store.prune()
    check(store.archive.clips.count == 500, "history cap")
    let data = try! JSONEncoder().encode(store.archive); let decoded = try! JSONDecoder().decode(Archive.self, from: data)
    check(decoded.clips[0].parts == store.archive.clips[0].parts, "pasteboard bytes preserved")
    let isolated = Store(ephemeral: true)
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    pb.setString("capture me", forType: .string)
    isolated.captureContents(pb, source: "Test", sourceID: "test")
    check(isolated.archive.clips.first?.text == "capture me", "actual pasteboard capture")
    pb.clearContents(); pb.setString("secret", forType: .string); pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    isolated.captureContents(pb, source: "Test", sourceID: "test")
    check(isolated.archive.clips.count == 1, "sensitive marker excluded")
    pb.clearContents(); pb.setString("ignored secret", forType: .string)
    isolated.ignored = "test"; isolated.captureContents(pb, source: "Test", sourceID: "test")
    check(isolated.archive.clips.count == 1, "excluded app skipped")
    isolated.ignored = ""; isolated.paused = true; isolated.captureContents(pb, source: "Test", sourceID: "test")
    check(isolated.archive.clips.count == 1, "pause prevents recording")
    isolated.paused = false; pb.clearContents(); pb.setString("https://example.com", forType: .string)
    isolated.captureContents(pb, source: "Test", sourceID: "test")
    check(isolated.archive.clips[0].kind == "链接", "link classification")
    pb.clearContents(); pb.setData(Data([1, 2, 3]), forType: .png)
    isolated.captureContents(pb, source: "Test", sourceID: "test")
    check(isolated.archive.clips[0].kind == "图片", "image classification")
    check(isolated.restore(clip("restore test"), plain: false, pasteboard: pb) && pb.string(forType: .string) == "restore test", "restore to isolated pasteboard")
    var rich = clip("plain text")
    rich.parts[0].append(ClipPart(type: "public.rtf", data: Data("{\\rtf1 styled}".utf8)))
    check(isolated.restore(rich, plain: true, pasteboard: pb) && pb.types?.contains(.rtf) == false && pb.string(forType: .string) == "plain text", "plain text strips rich formats")
    pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: "/tmp/openpaste-test.txt") as NSURL])
    isolated.captureContents(pb, source: "Finder", sourceID: "com.apple.finder")
    check(isolated.archive.clips[0].kind == "文件", "file reference classification")
    let deletion = Store(ephemeral: true)
    deletion.archive.clips = [clip("first"), clip("middle"), clip("last")]
    let lastID = deletion.archive.clips[2].id
    deletion.selected = deletion.archive.clips[1].id
    deletion.delete(deletion.selected!)
    check(deletion.archive.clips.count == 2 && deletion.selected == lastID, "delete selects adjacent remaining record")
    deletion.delete(lastID)
    check(deletion.selected == deletion.archive.clips.first?.id, "delete last selects previous record")
    deletion.delete(deletion.selected!)
    check(deletion.selected == nil && deletion.filtered.isEmpty, "delete final record clears selection")
    let reverse = Store(ephemeral: true)
    reverse.archive.clips = [clip("newest"), clip("middle"), clip("oldest")]
    let newestID = reverse.archive.clips[0].id
    reverse.reverseHistory = true
    check(reverse.filtered.map { $0.text } == ["oldest", "middle", "newest"] && reverse.selected == reverse.filtered.first?.id, "reverse selects oldest without changing archive order")
    reverse.delete(reverse.selected!)
    check(reverse.filtered.first?.text == "middle" && reverse.selected == reverse.filtered.first?.id, "reverse delete advances from oldest")
    reverse.reverseHistory = false
    check(reverse.filtered.first?.id == newestID && reverse.archive.clips.first?.id == newestID, "release restores normal history order")
    let unlimited = Store(ephemeral: true)
    unlimited.limit = 0
    unlimited.archive.clips = (0..<1100).map { clip("unlimited-\($0)") }
    unlimited.prune()
    check(unlimited.archive.clips.count == 1100, "unlimited history retains records beyond default count")
    check(MapLink.parse("https://maps.apple.com/frame?center=64.852473,-142.207031&distance=5457")?.coordinate == "64.852473, -142.207031", "Apple Maps frame center parsed")
    check(MapLink.parse("https://maps.apple.com/?q=北京&ll=39.9,116.4")?.name == "北京", "map place name decoded")
    check(MapLink.parse("https://maps.apple.com/?saddr=A&daddr=B")?.route == "A → B", "map route parsed")
    check(MapLink.parse("https://maps.apple.com.evil.test/?center=1,2") == nil && MapLink.parse("https://maps.apple.com/?center=999,2")?.coordinate == nil, "map host and coordinates validated")
    check(CapturedColor.parse("#1A2B3C")?.hex == "#1A2B3C" && CapturedColor.parse("abcdef") != nil, "six digit color codes captured")
    check(CapturedColor.parse("235442") == nil && CapturedColor.parse("#fff") == nil && CapturedColor.parse("rgb(0,0,0)") == nil, "numeric verification codes and shorthand remain text")
    let features = Store(ephemeral: true)
    features.archive.clips = [clip("one"), clip("two"), clip("three")]
    features.choose(features.archive.clips[0].id); features.choose(features.archive.clips[2].id, modifiers: .shift)
    check(features.selectedClips.count == 3, "shift selection covers range")
    features.choose(features.archive.clips[1].id, modifiers: .command)
    check(features.selectedClips.map(\.text) == ["one", "three"], "command toggles selected record")
    check(features.restoreMany(features.selectedClips, plain: false, pasteboard: pb) && pb.string(forType: .string) == "one\nthree" && pb.data(forType: .rtf) != nil, "batch text paste retains rich format")
    features.deleteChosen(); check(features.archive.clips.map(\.text) == ["two"], "batch delete removes only selected records")
    features.undoItemChange(); check(features.archive.clips.count == 3, "undo restores batch deletion")
    let styledSample = NSAttributedString(string: "Styled", attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.red])
    let richData = try! styledSample.data(from: NSRange(location: 0, length: styledSample.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    var richClip = clip("Styled"); richClip.parts[0].append(ClipPart(type: "public.rtf", data: richData))
    features.archive.clips = [richClip]; var renamed = richClip; renamed.title = "Label"; features.replace(renamed, label: "重命名")
    check(features.archive.clips[0].parts == richClip.parts && features.archive.clips[0].attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont != nil, "rename preserves original rich clipboard bytes")
    features.undoItemChange(); check(features.archive.clips[0].title == richClip.title, "undo restores item metadata")
    var screenshot = fixtureImage(); screenshot.ocrText = "识别结果 OCR needle"; features.archive.clips = [screenshot]; features.query = "needle"; check(features.filtered.count == 1, "search indexes recognized image text")
    check(!LinkPreviewCache.allowed(URL(string: "http://127.0.0.1/private")!) && !LinkPreviewCache.allowed(URL(string: "https://example.com/?token=secret")!) && LinkPreviewCache.allowed(URL(string: "https://www.apple.com/mac/")!), "preview policy rejects local and credential URLs")
    let rotatedPart = ImageTools.rotated(fixtureImage())!
    let rotatedSource = CGImageSourceCreateWithData(rotatedPart.data as CFData, nil)!
    let rotatedImage = CGImageSourceCreateImageAtIndex(rotatedSource, 0, nil)!
    check(rotatedImage.width == 2000 && rotatedImage.height == 3200, "rotation preserves full pixel dimensions")
    let recognized = Store.recognize(fixtureOCRImage())
    check(recognized.contains("OpenPaste") && recognized.contains("2026"), "Vision recognizes actual image text")
    let retention = Store(ephemeral: true); retention.retentionDays = 1
    var expired = clip("old"); expired.created = Date().addingTimeInterval(-2 * 86400)
    var favorite = expired; favorite.id = UUID(); favorite.boards = [UUID()]
    retention.archive.clips = [clip("today"), expired, favorite]; retention.prune()
    check(retention.archive.clips.count == 2 && retention.archive.clips.contains(where: { $0.id == favorite.id }), "time retention excludes favorites")
    features.query = ""; features.archive.clips = [clip("one"), clip("two"), clip("three")]; features.choose(features.archive.clips[0].id); features.choose(features.archive.clips[1].id, modifiers: .shift); features.choose(features.archive.clips[2].id, modifiers: .shift)
    check(features.selectedClips.count == 3, "repeated shift selection keeps original anchor")
    pb.clearContents(); pb.setString("#FF0000", forType: .string); let colorCapture = Store(ephemeral: true); colorCapture.captureContents(pb, source: "Test", sourceID: "test")
    check(colorCapture.archive.clips.first?.kind == "颜色" && colorCapture.archive.clips.first?.text == "#FF0000", "actual clipboard capture creates color item without changing text")
    let currentDeletion = Store(ephemeral: true)
    pb.clearContents(); pb.setString("delete-current-fixture", forType: .string)
    currentDeletion.capture(force: true, pasteboard: pb)
    let currentID = currentDeletion.currentClipID!
    currentDeletion.delete(currentID)
    currentDeletion.capture(force: true, pasteboard: pb)
    check(currentDeletion.archive.clips.isEmpty && currentDeletion.currentClipID == nil, "deleted current item is not recaptured on shelf reopen")
    check(pb.string(forType: .string) == "delete-current-fixture", "deleting current history preserves system clipboard")
    currentDeletion.undoItemChange()
    check(currentDeletion.archive.clips.count == 1 && currentDeletion.currentClipID == currentID, "undo restores deleted current item")
    currentDeletion.delete(currentID)
    pb.clearContents(); pb.setString("delete-current-fixture", forType: .string)
    currentDeletion.capture(force: true, pasteboard: pb)
    check(currentDeletion.archive.clips.count == 1 && currentDeletion.currentClipID != nil, "copying identical text again permits a new history record")
    currentDeletion.clearHistory()
    currentDeletion.capture(force: true, pasteboard: pb)
    check(currentDeletion.archive.clips.isEmpty, "clear history also suppresses unchanged current clipboard")
    print("\(passed) tests passed")
}

func runShortcutTests() {
    func check(_ value: Bool, _ name: String) { guard value else { print("FAIL: \(name)"); exit(1) }; print("PASS: \(name)") }
    check(GlobalShortcut.standard.valid && GlobalShortcut.standard.label == "⇧⌘V", "default shortcut")
    let bare = GlobalShortcut(keyCode: 9, modifiers: 0, keyName: "V")
    check(!bare.valid, "plain key rejected")
    check(!GlobalShortcut(keyCode: 9, modifiers: UInt32(cmdKey), keyName: "V").valid, "ordinary command shortcut rejected")
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
    let parsed = GlobalShortcut.from(event)
    check(parsed.valid && parsed.label == "⌃⌥K" && parsed.keyCode == 40, "record key and modifiers")
    let suite = "OpenPaste-shortcut-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    parsed.save(to: defaults)
    check(GlobalShortcut.load(from: defaults) == parsed, "shortcut persistence")
    defaults.set(Data("broken".utf8), forKey: "globalShortcut")
    check(GlobalShortcut.load(from: defaults) == .standard, "invalid saved shortcut falls back")
}

func runNavigationTests() {
    let store = Store(ephemeral: true)
    let clips = (0..<5000).map { index in
        let text = "Item \(index) " + String(repeating: "long preview text ", count: 500)
        return Clip(source: "Fixture", sourceID: "", kind: "文字", title: "Item \(index)", text: text, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]])
    }
    store.archive.clips = clips
    let passes = store.filterPasses
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<2000 { store.moveSelection(1) }
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    guard store.selected == clips[2000].id, store.filterPasses == passes else { print("FAIL: navigation recomputes results or loses selection"); exit(1) }
    store.query = "Item 4999 "
    guard store.filtered.count == 1, store.selected == clips[4999].id else { print("FAIL: filtering keeps stale selection"); exit(1) }
    print(String(format: "PASS: 5000-item navigation, 2000 moves in %.3f s, no refilter; query selects valid result", elapsed))
}

func fixtureImage() -> Clip {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3200, pixelsHigh: 2000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    memset(rep.bitmapData!, 255, rep.bytesPerRow * rep.pixelsHigh)
    let data = rep.representation(using: .png, properties: [:])!
    return Clip(source: "Fixture", sourceID: "", kind: "图片", title: "3200 × 2000 测试图片", text: "", parts: [[ClipPart(type: "public.png", data: data)]])
}
func runPreviewTests() {
    let clip = fixtureImage()
    let cache = PreviewCache()
    var image: NSImage?
    var completed = false
    cache.load(clip) { image = $0; completed = true }
    let deadline = Date().addingTimeInterval(5)
    while !completed && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    guard completed, let image = image, image.size.width <= 600, image.size.height <= 600 else { print("FAIL: bounded image preview"); exit(1) }
    let decodes = cache.decodeCount
    for _ in 0..<100 { cache.load(clip) { guard $0 != nil else { print("FAIL: preview cache miss"); exit(1) } } }
    guard cache.decodeCount == decodes else { print("FAIL: navigation decodes image again"); exit(1) }
    print("PASS: 3200x2000 image reduced to 600px, 100 reuse calls do not decode again")
}

func runCurrentClipboardTests() {
    func check(_ ok: Bool, _ name: String) { guard ok else { print("FAIL: \(name)"); exit(1) }; print("PASS: \(name)") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPaste-capture-\(UUID())")
    let store = Store(root: root)
    defer { store.flush(); try? FileManager.default.removeItem(at: root) }
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    pb.setString("Existing clipboard before launch", forType: .string)
    store.change = pb.changeCount
    store.capture(pasteboard: pb)
    check(store.archive.clips.isEmpty, "unchanged clipboard only polled when forced")
    store.capture(force: true, pasteboard: pb)
    check(store.archive.clips.count == 1 && store.archive.clips[0].text == "Existing clipboard before launch" && store.currentClipID == store.archive.clips[0].id, "existing clipboard enters history")
    let copied = store.archive.clips[0]
    store.capture(force: true, pasteboard: pb)
    check(store.archive.clips.count == 1 && store.archive.clips[0].created == copied.created, "reopen does not duplicate or rewrite existing clip")
    store.flush()
    check(Store(root: root).archive.clips.count == 1, "current clipboard survives restart")
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3200, pixelsHigh: 2000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    memset(rep.bitmapData!, 255, rep.bytesPerRow * rep.pixelsHigh)
    let tiff = rep.representation(using: .tiff, properties: [.compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.none.rawValue)])!
    check(tiff.count > 20 * 1024 * 1024, "large screenshot fixture exceeds old limit")
    pb.clearContents(); pb.setData(tiff, forType: .tiff)
    store.captureContents(pb, source: "Screenshot", sourceID: "com.apple.screencaptureui")
    check(store.archive.clips[0].kind == "图片" && store.archive.clips[0].parts[0][0].type == "public.png" && store.archive.clips[0].byteCount < 20 * 1024 * 1024, "TIFF screenshot is saved as lossless PNG")
    let imageID = store.archive.clips[0].id
    let png = store.archive.clips[0].parts[0][0].data
    pb.clearContents(); pb.setData(png, forType: .png); pb.setData(tiff, forType: .tiff)
    store.captureContents(pb, source: "Screenshot", sourceID: "com.apple.screencaptureui")
    check(store.archive.clips[0].id == imageID && store.archive.clips.count == 2, "PNG and TIFF representations create one history item")
    store.flush()
    let loaded = Store(root: root)
    check(loaded.archive.clips.count == 2 && loaded.archive.clips[0].kind == "图片" && loaded.archive.clips[0].image != nil, "screenshot survives restart with image bytes")
    let restore = NSPasteboard.withUniqueName()
    defer { restore.releaseGlobally() }
    check(loaded.restore(loaded.archive.clips[0], plain: false, pasteboard: restore) && restore.data(forType: .png) == png, "saved screenshot can be returned to clipboard")
    pb.clearContents(); pb.setData(tiff, forType: .tiff)
    store.captureContents(pb, source: "Screenshot", sourceID: "com.apple.screencaptureui", backgroundImages: true)
    store.flush()
    check(store.currentClipID == imageID && Store(root: root).archive.clips.count == 2, "background screenshot is committed before exit")
    store.paused = true
    pb.clearContents(); pb.setString("Do not store while paused", forType: .string)
    store.capture(force: true, pasteboard: pb)
    check(store.archive.clips.count == 2, "forced current import respects pause")
}

func runPasteImportTests() {
    func check(_ ok: Bool, _ name: String) { guard ok else { print("FAIL: \(name)"); exit(1) }; print("PASS: \(name)") }
    do {
        let result = try PasteImport.read(existing: Archive())
        print(result.summary)
        check(!result.clips.isEmpty && result.databases > 0, "actual Paste databases decode")
        check(result.total == result.clips.count + result.duplicate + result.unreadable + result.oversized + result.capacity, "all source records accounted for")
        check(result.clips.allSatisfy { !$0.parts.isEmpty && $0.byteCount > 0 }, "original clipboard payload preserved")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPaste-import-test-\(UUID())")
        let store = Store(root: root)
        defer { store.flush(); try? FileManager.default.removeItem(at: root) }
        let sentinel = Clip(source: "Test", sourceID: "test", kind: "文字", title: "existing", text: "existing", parts: [[ClipPart(type: "public.utf8-plain-text", data: Data("import-sentinel".utf8))]])
        store.ingest(sentinel)
        let added = try store.applyPasteImport(result)
        check(added > 0 && store.archive.clips.contains { $0.id == sentinel.id }, "import preserves existing history")
        check(try store.applyPasteImport(result) == 0, "repeat import is idempotent")
        let reloaded = Store(root: root)
        check(reloaded.archive.clips.count == store.archive.clips.count, "import persists past original history limit")
        check(reloaded.archive.boards.count == store.archive.boards.count, "boards persist")
        check(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("before-paste-import-") }, "pre-import backup exists")
        let pb = NSPasteboard(name: .init("OpenPaste-import-test-\(UUID())"))
        defer { pb.releaseGlobally() }
        for kind in ["文字", "链接", "图片", "文件"] {
            if let clip = result.clips.first(where: { $0.kind == kind }) { check(store.restore(clip, plain: false, pasteboard: pb) && pb.pasteboardItems?.count == clip.parts.count, "restore imported \(kind)") }
        }
        print(result.summary)
    } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
}

func runPasteImportUnitTests() {
    func check(_ ok: Bool, _ name: String) { guard ok else { print("FAIL: \(name)"); exit(1) }; print("PASS: \(name)") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPaste-import-fixture-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = folder.appendingPathComponent("db.sqlite")
        var db: OpaquePointer?; sqlite3_open(database.path, &db)
        defer { sqlite3_close(db) }
        let schema = "CREATE TABLE ZITEMENTITY(Z_PK INTEGER,ZTIMESTAMP REAL,ZTITLE TEXT,ZSOURCEAPPLICATION INTEGER,ZDATA INTEGER,ZLIST INTEGER); CREATE TABLE ZAPPLICATIONENTITY(Z_PK INTEGER,ZNAME TEXT,ZBUNDLEIDENTIFIER TEXT); CREATE TABLE ZITEMDATAENTITY(Z_PK INTEGER,ZRAWPASTEBOARDITEMS BLOB); CREATE TABLE ZLISTENTITY(Z_PK INTEGER,ZNAME TEXT,ZIDENTIFIER TEXT,ZRAWTYPE INTEGER); INSERT INTO ZAPPLICATIONENTITY VALUES(1,'Editor','test.editor'); INSERT INTO ZLISTENTITY VALUES(1,'Saved','saved',2);"
        check(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK, "fixture database created")
        let parts = [ClipPart(type: "public.utf8-plain-text", data: Data("func hello() {\n    return\n}".utf8)), ClipPart(type: "public.rtf", data: Data("{\\rtf1 hello}".utf8))]
        let json = try JSONSerialization.data(withJSONObject: [["types": parts.map(\.type), "dataByType": Dictionary(uniqueKeysWithValues: parts.map { ($0.type, $0.data.base64EncodedString()) })]])
        let binary = try PropertyListSerialization.data(fromPropertyList: [["types": parts.map(\.type), "dataByType": Dictionary(uniqueKeysWithValues: parts.map { ($0.type, $0.data) })]], format: .binary, options: 0)
        check(try PasteImport.decode(binary) == [parts], "modern binary plist payload decoded")
        var compressed = Data(count: json.count * 2 + 1024)
        let count = compressed.withUnsafeMutableBytes { output in json.withUnsafeBytes { input in compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count, input.bindMemory(to: UInt8.self).baseAddress!, json.count, nil, COMPRESSION_ZLIB) } }
        compressed.count = count
        check(count > 0, "compressed fixture created")
        let inline = Data([1]) + compressed
        check(try PasteImport.decode(PasteImport.payload(inline, database: database)) == [parts], "compressed text and RTF restored byte-for-byte")
        let external = folder.appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let name = UUID().uuidString; try compressed.write(to: external.appendingPathComponent(name))
        let reference = Data([2]) + Data(name.utf8)
        check(try PasteImport.decode(PasteImport.payload(reference, database: database)) == [parts], "external payload decoded")
        do { _ = try PasteImport.payload(Data([2]) + Data("../outside".utf8), database: database); check(false, "path traversal rejected") } catch { check(true, "path traversal rejected") }
        for (id, data) in [(1,inline),(2,reference),(3,Data([99]))] {
            sqlite3_exec(db, "INSERT INTO ZITEMENTITY VALUES(\(id),12345,'Code',1,\(id),1)", nil,nil,nil)
            var statement: OpaquePointer?; sqlite3_prepare_v2(db,"INSERT INTO ZITEMDATAENTITY VALUES(?,?)",-1,&statement,nil)
            sqlite3_bind_int(statement,1,Int32(id))
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement,2,$0.baseAddress,Int32(data.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
            check(sqlite3_step(statement) == SQLITE_DONE, "fixture row stored")
            sqlite3_finalize(statement)
        }
        let result = try PasteImport.read(existing: Archive(), urls: [database])
        check(result.clips.count == 1 && result.duplicate == 1 && result.unreadable == 1, "duplicate and corrupt rows accounted for")
        check(result.clips[0].created == Date(timeIntervalSinceReferenceDate:12345) && result.clips[0].sourceID == "test.editor", "source and timestamp preserved")
        check(result.boards.count == 1 && result.clips[0].boards == [result.boards[0].id], "pinboard membership preserved")
        let existing = Archive(clips: result.clips, boards: [])
        let repeatRead = try PasteImport.read(existing: existing, urls:[database])
        check(repeatRead.clips.isEmpty && repeatRead.duplicate == 2 && !repeatRead.memberships.isEmpty, "existing duplicates retain incoming board membership")
        let store = Store(root: folder.appendingPathComponent("OpenPaste")); store.archive = existing; store.save(); store.flush()
        check(try store.applyPasteImport(repeatRead) == 0 && store.archive.clips[0].parts == [parts], "duplicate import preserves original payload")
        var expanded = repeatRead; expanded.byteLimit = 500 * 1024 * 1024
        _ = try store.applyPasteImport(expanded)
        check(store.maxArchiveBytes >= store.archive.clips.reduce(0) { $0 + $1.byteCount } && store.archive.clips[0].parts == [parts], "imported content retained without a fixed budget")
        let backup = try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("before-paste-import-") }!
        let backupArchive = try HistoryStorage.read(from: backup)
        check(backupArchive.clips[0].parts == [parts], "backup retains original bytes using immutable content files")
        let manifest = store.root.appendingPathComponent("history.json")
        check(try Data(contentsOf: manifest).count < 4096, "history manifest contains references instead of base64 payloads")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 100, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        let tiff = bitmap.tiffRepresentation!
        let imageParts = [ClipPart(type: "public.png", data: png), ClipPart(type: "public.tiff", data: tiff)]
        let canonical = PasteImport.canonicalParts([imageParts])
        check(canonical[0].count == 1 && canonical[0][0].data == png && canonical[0][0].data.count < tiff.count, "image representations merged losslessly before capacity checks")
        for id in [4,5] {
            let data = Data([1]) + (try JSONSerialization.data(withJSONObject: [["types": imageParts.map(\.type), "dataByType": Dictionary(uniqueKeysWithValues: imageParts.map { ($0.type, $0.data.base64EncodedString()) })]]))
            sqlite3_exec(db, "INSERT INTO ZITEMENTITY VALUES(\(id),12346,'Image',1,\(id),1)",nil,nil,nil)
            var statement: OpaquePointer?; sqlite3_prepare_v2(db,"INSERT INTO ZITEMDATAENTITY VALUES(?,?)",-1,&statement,nil)
            sqlite3_bind_int(statement,1,Int32(id)); _ = data.withUnsafeBytes { sqlite3_bind_blob(statement,2,$0.baseAddress,Int32(data.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
            check(sqlite3_step(statement) == SQLITE_DONE,"image fixture stored");sqlite3_finalize(statement)
        }
        var progress: [ImportProgress] = []
        let automatic = try PasteImport.read(existing: Archive(), urls: [database], progress: { progress.append($0) })
        check(automatic.capacity == 0 && automatic.clips.filter { $0.kind == "图片" }.count == 1, "automatic disk budget and canonical image deduplication")
        check(progress.first?.completed == 0 && progress.last?.phase == "解析完成" && progress.last?.completed == 5, "parsing progress reaches actual record total")
        var writeProgress: [ImportProgress] = []
        let newRoot = folder.appendingPathComponent("NewImport")
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories:true)
        let (imported, importedCount) = try PasteImport.commit(automatic, snapshot: Archive(), root: newRoot, progress: { writeProgress.append($0) })
        check(importedCount == 2 && imported.clips.count == 2 && writeProgress.contains { $0.phase == "导入内容" && $0.completed == 1 } && writeProgress.last?.phase == "导入完成", "import progress follows backup, payload writes and final commit")
        let before = try Data(contentsOf: newRoot.appendingPathComponent("history.json"))
        let invalid = folder.appendingPathComponent("not-a-directory"); try Data("blocked".utf8).write(to: invalid)
        do { _ = try PasteImport.commit(automatic, snapshot: imported, root: invalid); check(false,"failed import rejected") } catch { check(try Data(contentsOf: newRoot.appendingPathComponent("history.json")) == before,"failed import leaves committed history intact") }
        print("Paste import unit tests passed")
    } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
}

func fixtureOCRImage() -> Clip {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1200, height: 400)).fill()
    ("OpenPaste OCR 2026" as NSString).draw(in: NSRect(x: 60, y: 120, width: 1100, height: 170), withAttributes: [.font: NSFont.systemFont(ofSize: 80), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    return Clip(created: Date().addingTimeInterval(-300), source: "测试图片", sourceID: "", kind: "图片", title: "OCR 测试图片", text: "", parts: [[ClipPart(type: "public.png", data: rep.representation(using: .png, properties: [:])!)]])
}

func runDragProviderTests() {
    let clip = fixtureOCRImage()
    let provider = clip.dragProvider()
    var completed = false
    var identifier: String?
    provider.loadDataRepresentation(forTypeIdentifier: "io.github.SwallOwDili.OpenPaste.clip-id") { data, error in
        identifier = data.flatMap { String(data: $0, encoding: .utf8) }; completed = true
        if let error { print("Provider error: \(error.localizedDescription)") }
    }
    let until = Date().addingTimeInterval(5)
    while !completed && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    guard completed, identifier == clip.id.uuidString else { print("FAIL: image drag does not preserve item identifier"); exit(1) }
    print("PASS: image drag resolves original item identifier")
    completed = false; var fileOK = false
    provider.loadFileRepresentation(forTypeIdentifier: "public.png") { url, _ in fileOK = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false; completed = true }
    let deadline = Date().addingTimeInterval(5)
    while !completed && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    guard completed, fileOK else { print("FAIL: image drag does not provide PNG file"); exit(1) }
    print("PASS: image drag provides a readable PNG file")
}
