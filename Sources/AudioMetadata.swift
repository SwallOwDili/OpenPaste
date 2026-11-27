import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// What the audio preview shows about a file. Tags come from the file; missing ones stay nil.
struct AudioInfo: Equatable {
    var title: String
    var artist: String?
    var album: String?
    var format: String
    var duration: Double?
    var artwork: Data?
    /// “Artist · Album”, whichever parts exist.
    var detail: String? { [artist, album].compactMap { $0 }.joined(separator: " · ").nilIfEmpty }

    static func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }

    /// Reads tags off the UI thread. FLAC is parsed directly (AVFoundation does not map its
    /// Vorbis comments or pictures to common metadata); other formats use AVFoundation.
    static func load(_ url: URL, duration includeDuration: Bool = true) async -> AudioInfo {
        var info = AudioInfo(title: url.deletingPathExtension().lastPathComponent, format: url.pathExtension.uppercased())
        let asset = AVURLAsset(url: url)
        if includeDuration, let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 { info.duration = duration.seconds }
        if url.pathExtension.lowercased() == "flac" {
            if let flac = FLACMetadata.read(url) {
                info.title = flac.tags["TITLE"] ?? info.title
                info.artist = flac.tags["ARTIST"]; info.album = flac.tags["ALBUM"]; info.artwork = flac.picture
            }
            return info
        }
        for item in (try? await asset.load(.commonMetadata)) ?? [] {
            switch item.commonKey {
            case .commonKeyTitle: if let value = try? await item.load(.stringValue), !value.isEmpty { info.title = value }
            case .commonKeyArtist: info.artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName: info.album = try? await item.load(.stringValue)
            case .commonKeyArtwork: info.artwork = try? await item.load(.dataValue)
            default: break
            }
        }
        return info
    }
}

/// FLAC metadata blocks: VORBIS_COMMENT tags (upper-cased keys) and the first PICTURE
/// (front cover preferred). Only the metadata region before the audio frames is read.
enum FLACMetadata {
    static let maxPicture = 16 * 1024 * 1024

    static func read(_ url: URL) -> (tags: [String: String], picture: Data?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }
        var tags: [String: String] = [:], picture: Data?, pictureIsFront = false
        while let header = try? handle.read(upToCount: 4), header.count == 4 {
            let type = header[0] & 0x7F, last = header[0] & 0x80 != 0
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if type == 4 || (type == 6 && length <= maxPicture + 4096) {
                guard let body = try? handle.read(upToCount: length), body.count == length else { return (tags, picture) }
                if type == 4 { tags.merge(comments(body)) { first, _ in first } }
                else if let parsed = self.picture(body), picture == nil || (!pictureIsFront && parsed.front) { picture = parsed.data; pictureIsFront = parsed.front }
            } else {
                guard let offset = try? handle.offset(), (try? handle.seek(toOffset: offset + UInt64(length))) != nil else { return (tags, picture) }
            }
            if last { break }
        }
        return (tags, picture)
    }

    static func comments(_ body: Data) -> [String: String] {
        let bytes = [UInt8](body)
        func u32le(_ at: Int) -> Int? { at + 4 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 : nil }
        guard let vendor = u32le(0), let count = u32le(4 + vendor) else { return [:] }
        var at = 8 + vendor, result: [String: String] = [:]
        for _ in 0..<min(count, 1000) {
            guard let length = u32le(at), at + 4 + length <= bytes.count else { break }
            let entry = String(decoding: bytes[(at + 4)..<(at + 4 + length)], as: UTF8.self)
            at += 4 + length
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<equals].uppercased(), value = String(entry[entry.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, result[key] == nil { result[key] = value }
        }
        return result
    }

    static func picture(_ body: Data) -> (data: Data, front: Bool)? {
        let bytes = [UInt8](body)
        func u32be(_ at: Int) -> Int? { at + 4 <= bytes.count ? Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) : nil }
        guard let kind = u32be(0), let mime = u32be(4), let description = u32be(8 + mime) else { return nil }
        let dataLengthAt = 12 + mime + description + 16
        guard let length = u32be(dataLengthAt), length > 0, dataLengthAt + 4 + length <= bytes.count else { return nil }
        return (Data(bytes[(dataLengthAt + 4)..<(dataLengthAt + 4 + length)]), kind == 3)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
