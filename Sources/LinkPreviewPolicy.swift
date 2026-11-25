import Foundation

/// A conservative URL heuristic, not a guarantee about DNS or server behavior.
/// Suspect URLs can be fetched only after an explicit action on their card.
enum LinkPreviewPolicy {
    static func canLoad(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
            url.user == nil && url.password == nil && !(url.host ?? "").isEmpty
    }

    /// Loadable and not a literal IP, local-only or intranet-looking host.
    static func publicHost(_ url: URL) -> Bool {
        guard canLoad(url), let rawHost = url.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let privateSuffixes = ["local", "internal", "localhost", "lan", "corp", "home", "home.arpa"]
        return host.contains(".") && !host.contains(":") &&
            host.range(of: "^[0-9.]+$", options: .regularExpression) == nil && !PublicAddress.isNumericHost(host) &&
            !privateSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    /// `publicHost`, and the name resolves only to public addresses. Blocking: background queues only.
    static func publicAddress(_ url: URL) -> Bool { publicHost(url) && PublicAddress.isPublic(host: url.host ?? "") }

    /// `automatic`, and the name resolves only to public addresses. Blocking: background queues only.
    static func automaticResolved(_ url: URL) -> Bool { automatic(url) && PublicAddress.isPublic(host: url.host ?? "") }

    /// Sites whose automatic previews may use the system's `LPMetadataProvider`. It follows redirects and loads
    /// sub-resources without any check, so every other site is fetched with the restricted loader.
    static let systemFetchHosts = ["youtube.com", "youtu.be", "music.apple.com", "apps.apple.com", "podcasts.apple.com", "maps.apple.com", "tv.apple.com", "books.apple.com"]
    static func systemFetchAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return systemFetchHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func automatic(_ url: URL) -> Bool {
        guard publicHost(url) else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let sensitiveNames = ["token", "key", "secret", "password", "auth", "signature", "credential", "ticket", "nonce", "session", "passcode", "jwt", "otp"]
        for item in components?.queryItems ?? [] {
            let name = item.name.lowercased()
            if name == "code" || sensitiveNames.contains(where: { name.contains($0) }) { return false }
        }
        let path = url.path.lowercased().split(separator: "/").map(String.init)
        let actions: Set<String> = ["login", "signin", "sign-in", "logout", "signout", "auth", "oauth", "authorize", "callback", "verify", "verification", "activate", "activation", "redeem", "reset", "reset-password", "unsubscribe", "magic-link", "invite"]
        guard !path.contains(where: { actions.contains($0) || $0.count >= 40 }) else { return false }
        // Fragments can hold credentials even though they are not part of an HTTP request.
        return (components?.fragment ?? "").isEmpty
    }
}

extension Store {
    func applyLinkPreview(_ result: LinkPreviewResult, to clip: Clip) {
        guard canModifyHistory, networkPreviews,
              let index = archive.clips.firstIndex(where: { $0.id == clip.id && $0.text == clip.text }) else { return }
        let metadata = result.title + "\n" + result.subtitle + (result.videoTitle.map { "\n" + $0 } ?? "")
        guard archive.clips[index].linkTitle != metadata else { return }
        archive.clips[index].linkTitle = metadata
        noteUnsavedLinkTitle()
    }
}
