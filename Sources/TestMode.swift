// Fixture entry points exist only in the dedicated acceptance build.
enum TestMode {
    static var translationWorkflow: Bool {
        #if OPENPASTE_TESTING
        CommandLine.arguments.contains("--translation-workflow-test")
        #else
        false
        #endif
    }
    static var translationUI: Bool {
        #if OPENPASTE_TESTING
        CommandLine.arguments.contains("--translation-ui-test")
        #else
        false
        #endif
    }
    static var featureUI: Bool {
        #if OPENPASTE_TESTING
        CommandLine.arguments.contains("--feature-ui-test")
        #else
        false
        #endif
    }
    static var preview: Bool {
        #if OPENPASTE_TESTING
        CommandLine.arguments.contains("--preview")
        #else
        false
        #endif
    }
    static var layout: Bool {
        #if OPENPASTE_TESTING
        CommandLine.arguments.contains("--layout-test")
        #else
        false
        #endif
    }
    static var shortcut: Bool {
        #if OPENPASTE_TESTING
        CommandLine.arguments.contains("--shortcut-test")
        #else
        false
        #endif
    }
    static var ui: Bool {
        #if OPENPASTE_TESTING
        CommandLine.arguments.contains("--ui-test")
        #else
        false
        #endif
    }
    static var keyboard: Bool {
        #if OPENPASTE_TESTING
        CommandLine.arguments.contains("--keyboard-test")
        #else
        false
        #endif
    }
    static var forceManual: Bool {
        #if OPENPASTE_TESTING
        CommandLine.arguments.contains("--force-manual")
        #else
        false
        #endif
    }
    static var active: Bool {
        #if OPENPASTE_TESTING
        CommandLine.arguments.contains { $0.hasSuffix("-test") }
        #else
        false
        #endif
    }
}
