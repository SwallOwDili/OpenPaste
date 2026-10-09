import Foundation

/// A conservative URL heuristic, not a guarantee about DNS or server behavior.
/// Suspect URLs can be fetched only after an explicit action on their card.
enum LinkPreviewPolicy {
    static func canLoad(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
            url.user == nil && url.password == nil && !(url.host ?? "").isEmpty
    }

    static func automatic(_ url: URL) -> Bool {
        guard canLoad(url), let rawHost = url.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let privateSuffixes = ["local", "internal", "localhost", "lan", "corp", "home", "home.arpa"]
        guard host.contains("."), !host.contains(":"),
              host.range(of: "^[0-9.]+$", options: .regularExpression) == nil,
              !privateSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
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
        let metadata = result.title + "\n" + result.subtitle
        guard archive.clips[index].linkTitle != metadata else { return }
        archive.clips[index].linkTitle = metadata
        save()
    }
}
