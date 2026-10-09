import AppKit

enum ContentEdit {
    case text(NSAttributedString)
    case color(String)
}

enum ContentEditTarget {
    case existing(UUID)
    case new(Clip)
}

private struct EditedContent {
    let text: String
    let title: String
    let kind: String
    let parts: [[ClipPart]]
}

extension Store {
    func contentEditTarget(for clip: Clip) -> ContentEditTarget {
        archive.clips.contains(where: { $0.id == clip.id }) ? .existing(clip.id) : .new(clip)
    }

    @discardableResult
    func saveContentEdit(_ edit: ContentEdit, to target: ContentEditTarget, label: String = "编辑") -> Bool {
        guard canModifyHistory else { message = historyModificationNotice; return false }
        switch target {
        case .existing(let id):
            guard let index = archive.clips.firstIndex(where: { $0.id == id }) else {
                message = "内容已被删除，编辑未保存"
                return false
            }
            guard let updated = editedClip(from: archive.clips[index], applying: edit) else { return false }
            remember([archive.clips[index]], label: label)
            archive.clips[index] = updated
            save()
            return true

        case .new(let draft):
            guard let created = editedClip(from: draft, applying: edit) else { return false }
            guard !created.text.isEmpty else {
                message = "内容为空，未创建"
                return false
            }
            guard let id = ingest(created) else { return false }
            if id == created.id {
                undoItems.append(ItemUndo(clips: [], ids: [id], label: "新建"))
                if undoItems.count > 10 { undoItems.removeFirst() }
            }
            choose(id)
            return true
        }
    }

    private func editedClip(from current: Clip, applying edit: ContentEdit) -> Clip? {
        guard let content = editedContent(edit) else { return nil }
        var updated = current
        updated.text = content.text
        if current.userLabel == nil { updated.title = content.title }
        updated.kind = content.kind
        updated.parts = content.parts
        updated.linkTitle = nil
        updated.cachedDigest = nil
        guard updated.byteCount <= 20 * 1024 * 1024 else {
            message = "内容超过单条 20 MB 上限"
            return nil
        }
        updated.cachedDigest = updated.fingerprint
        return updated
    }

    private func editedContent(_ edit: ContentEdit) -> EditedContent? {
        switch edit {
        case .text(let richText):
            let text = richText.string
            let plain = Data(text.utf8)
            guard plain.count <= 20 * 1024 * 1024 else {
                message = "内容超过单条 20 MB 上限"
                return nil
            }
            let kind = CapturedColor.parse(text) != nil ? "颜色" : (URL(string: text)?.scheme?.hasPrefix("http") == true ? "链接" : "文字")
            var parts = [ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: plain)]
            if let rtf = try? richText.data(from: NSRange(location: 0, length: richText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                parts.append(ClipPart(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf))
            }
            return EditedContent(text: text, title: String(text.prefix(100)), kind: kind, parts: [parts])

        case .color(let value):
            guard let color = CapturedColor.parse(value) else {
                message = "颜色值无效，编辑未保存"
                return nil
            }
            let data = Data(color.hex.utf8)
            return EditedContent(text: color.hex, title: color.hex, kind: "颜色", parts: [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: data)]])
        }
    }
}
