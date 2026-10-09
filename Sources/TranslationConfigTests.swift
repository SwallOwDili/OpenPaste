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
    print("Translation configuration: \(checks) checks passed")
}
