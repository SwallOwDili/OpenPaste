import AppKit
import Foundation

func runTranslationConfigTests() {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { print("FAIL: \(label)"); exit(1) }
        checks += 1
    }
    let suite = "OpenPaste.TranslationConfigTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let config = TranslationConfig(defaults: defaults)
    config.base = "https://example.com/v1"
    config.model = "fixture-model"
    config.language = "English"
    defaults.set("retained", forKey: "unrelatedSetting")

    check(config.key().isEmpty, "fresh configuration has no key")
    check(!config.save(newKey: "  "), "missing key is rejected")
    check(defaults.object(forKey: "translationBase") == nil, "failed validation saves no fields")
    check(config.save(newKey: "  fixture-key\n"), "key and translation fields save together")
    check(defaults.string(forKey: "translationAPIKey") == "fixture-key", "key uses the same preferences domain")
    let rebuilt = TranslationConfig(defaults: UserDefaults(suiteName: suite)!)
    check(rebuilt.key() == "fixture-key" && rebuilt.base == config.base && rebuilt.model == config.model && rebuilt.language == config.language, "configuration survives instance reconstruction")
    check(rebuilt.save(newKey: "\n ") && rebuilt.key() == "fixture-key", "blank input preserves the saved key")
    check(rebuilt.save(newKey: "replacement-key") && rebuilt.key() == "replacement-key", "new key replaces old value")
    check(defaults.string(forKey: "unrelatedSetting") == "retained", "save preserves other app settings")
    let savedRevision = rebuilt.revision
    rebuilt.base = "not a URL"
    check(!rebuilt.save(newKey: "must-not-save"), "invalid endpoint is rejected")
    rebuilt.base = "https://different.example/v1"
    rebuilt.model = " "
    check(!rebuilt.save(newKey: "must-not-save"), "empty model is rejected")
    check(rebuilt.key() == "replacement-key" && defaults.string(forKey: "translationBase") == config.base && defaults.string(forKey: "translationModel") == config.model, "invalid save preserves the entire saved configuration")
    check(rebuilt.revision == savedRevision, "failed validation keeps the saved revision")
    rebuilt.model = "updated-model"
    check(rebuilt.save(newKey: "") && rebuilt.revision == savedRevision + 1, "successful save advances the request revision")

    let otherSuite = "OpenPaste.TranslationConfigTests.\(UUID().uuidString)"
    let otherDefaults = UserDefaults(suiteName: otherSuite)!
    defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
    check(TranslationConfig(defaults: otherDefaults).key().isEmpty, "isolated profiles do not share keys")
    let saved = rebuilt.savedRequestConfiguration()
    rebuilt.base = "https://unsaved.example/v1"
    rebuilt.model = "unsaved-model"
    rebuilt.language = "unsaved-language"
    check(rebuilt.savedRequestConfiguration() == saved, "unsaved edits never enter outgoing request configuration")
    otherDefaults.set("https://other.example/v1", forKey: "translationBase")
    otherDefaults.set("other-model", forKey: "translationModel")
    otherDefaults.set("other-key", forKey: "translationAPIKey")
    let other = TranslationConfig(defaults: otherDefaults).savedRequestConfiguration()
    check(other.base == "https://other.example/v1" && other.model == "other-model" && other.key == "other-key", "all request fields use the injected domain")
    check(rebuilt.savedRequestConfiguration() == saved, "other profile changes cannot alter saved request configuration")
    do {
        let request = try TranslationAPI.request(base: saved.base, key: saved.key, model: saved.model, language: saved.language, text: "synthetic selection")
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        check(request.url?.host == "different.example" && json["model"] as? String == "updated-model", "actual request uses saved endpoint and model")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-key", "actual request uses the saved key from the same profile")
    } catch { print("FAIL: saved request construction: \(error)"); exit(1) }
    // Finder selections arrive as file references plus the file name as text.
    check(SelectionCapturePolicy.isFileSelection(types: [.fileURL, .string]), "file URL with a name string is a file selection")
    check(SelectionCapturePolicy.isFileSelection(types: [.string, NSPasteboard.PasteboardType("NSFilenamesPboardType")]), "legacy filenames type is a file selection")
    check(SelectionCapturePolicy.isFileSelection(types: [NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")]), "promised file URL is a file selection")
    check(!SelectionCapturePolicy.isFileSelection(types: [.string]), "plain text is not a file selection")
    check(!SelectionCapturePolicy.isFileSelection(types: [.string, .rtf, .html, .URL]), "rich text and web links stay translatable")
    check(!SelectionCapturePolicy.isFileSelection(types: []), "empty pasteboard is not a file selection")
    // Issue #26: Monaco editors copy the whole current line when nothing is selected. Real bytes from VS Code
    // 1.146.0 on macOS 15.6 (metadata only, no text), captured with an empty selection.
    let emptyLineCopy = Data(base64Encoded: "OAMAAAIAAAAhAAAAYQBwAHAAbABpAGMAYQB0AGkAbwBuAC8AdgBuAGQALgBjAG8AZABlAC4AYwBvAHAAeQBtAGUAdABhAGQAYQB0AGEAAADWAAAAewAiAGkAZAAiADoAIgA0ADYAOABiAGMANQBmAGEALQA2AGIAZABjAC0ANAA2ADQAYgAtAGIAZgBhAGYALQBkAGEAYQBhADgAOABmADkAZQAzADQAMAAiACwAIgBwAHIAbwB2AGkAZABlAHIAQwBvAHAAeQBNAGkAbQBlAFQAeQBwAGUAcwAiADoAWwAiAGEAcABwAGwAaQBjAGEAdABpAG8AbgAvAHYAbgBkAC4AYwBvAGQAZQAuAGEAZABkAGkAdABpAG8AbgBhAGwALQBlAGQAaQB0AG8AcgAtAGQAYQB0AGEAIgBdACwAIgBkAGUAZgBhAHUAbAB0AFAAYQBzAHQAZQBQAGEAeQBsAG8AYQBkACIAOgB7ACIAbQB1AGwAdABpAGMAdQByAHMAbwByAFQAZQB4AHQAIgA6AG4AdQBsAGwALAAiAHAAYQBzAHQAZQBPAG4ATgBlAHcATABpAG4AZQAiADoAdAByAHUAZQAsACIAaQBzAEIAbABvAGMAawAiADoAZgBhAGwAcwBlACwAIgBtAG8AZABlACIAOgBuAHUAbABsAH0AfQASAAAAdgBzAGMAbwBkAGUALQBlAGQAaQB0AG8AcgAtAGQAYQB0AGEAiAAAAHsAIgB2AGUAcgBzAGkAbwBuACIAOgAxACwAIgBpAGQAIgA6ACIAMQAxADgANwA2AGYAMAA0AC0AOQBlADYANwAtADQAMAAyADcALQA4AGIAOAA1AC0AMgA0ADkAOQAyADgAYQAyADYAMwA0AGQAIgAsACIAaQBzAEYAcgBvAG0ARQBtAHAAdAB5AFMAZQBsAGUAYwB0AGkAbwBuACIAOgB0AHIAdQBlACwAIgBpAHMAQgBsAG8AYwBrACIAOgBmAGEAbABzAGUALAAiAG0AdQBsAHQAaQBjAHUAcgBzAG8AcgBUAGUAeAB0ACIAOgBuAHUAbABsACwAIgBtAG8AZABlACIAOgBuAHUAbABsAH0A")!
    func pickle(_ pairs: [(String, String)]) -> Data {
        var body = Data()
        func u32(_ value: Int) { var v = UInt32(value).littleEndian; body.append(Data(bytes: &v, count: 4)) }
        u32(pairs.count)
        for (key, value) in pairs { for text in [key, value] { let units = Array(text.utf16); u32(units.count); for unit in units { var u = unit.littleEndian; body.append(Data(bytes: &u, count: 2)) }; if units.count % 2 == 1 { body.append(Data([0, 0])) } } }
        var size = UInt32(body.count).littleEndian
        return Data(bytes: &size, count: 4) + body
    }
    let parsed = SelectionCapturePolicy.chromiumCustomData(emptyLineCopy)
    check(parsed.keys.sorted() == ["application/vnd.code.copymetadata", "vscode-editor-data"], "real VS Code custom data parses into its two entries")
    check(SelectionCapturePolicy.isEmptySelectionLineCopy(customData: emptyLineCopy, editorData: nil), "VS Code line copy from an empty selection is recognised")
    let selectedCopy = pickle([("vscode-editor-data", #"{"version":1,"isFromEmptySelection":false,"multicursorText":null}"#)])
    check(SelectionCapturePolicy.chromiumCustomData(selectedCopy)["vscode-editor-data"]?.contains("false") == true, "odd-length strings are padded to 4 bytes")
    check(!SelectionCapturePolicy.isEmptySelectionLineCopy(customData: selectedCopy, editorData: nil), "a real selection in VS Code stays translatable")
    check(SelectionCapturePolicy.isEmptySelectionLineCopy(customData: nil, editorData: #"{"isFromEmptySelection":true}"#), "a direct vscode-editor-data type is also recognised")
    check(!SelectionCapturePolicy.isEmptySelectionLineCopy(customData: pickle([("text/x-other", #"{"isFromEmptySelection":true}"#)]), editorData: nil), "the flag only counts under vscode-editor-data")
    check(!SelectionCapturePolicy.isEmptySelectionLineCopy(customData: nil, editorData: nil), "apps without the marker keep today's behaviour")
    check(SelectionCapturePolicy.chromiumCustomData(emptyLineCopy.prefix(40)).isEmpty && SelectionCapturePolicy.chromiumCustomData(Data([1, 2, 3])).isEmpty, "truncated or malformed custom data is ignored without crashing")
    check(!SelectionCapturePolicy.isEmptySelectionLineCopy(customData: pickle([("vscode-editor-data", "not json")]), editorData: nil), "malformed editor JSON is not treated as an empty selection")
    print("Translation configuration: \(checks) checks passed")
}
