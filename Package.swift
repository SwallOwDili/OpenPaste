// swift-tools-version:5.9
import PackageDescription
import Foundation

let openPasteTesting = ProcessInfo.processInfo.environment["OPENPASTE_TESTING"] == "1"
let testOnlySources = [
    "CaptureBoundaryTests.swift",
    "ClipboardWriteTests.swift",
    "ContentEditingTests.swift",
    "FilterTests.swift",
    "InteractionPolicyTests.swift",
    "KeyboardTests.swift",
    "LinkPreviewBoundaryTests.swift",
    "MaintenanceTests.swift",
    "PasteQueueTests.swift",
    "PermissionMonitorTests.swift",
    "RecordingPauseTests.swift",
    "StorageRecoveryTests.swift",
    "Tests.swift",
    "TranslationConfigTests.swift",
    "UpdateTests.swift"
]

let package = Package(
    name: "OpenPaste",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OpenPaste", targets: ["OpenPaste"])],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", exact: "12.4.0")
    ],
    targets: [
        .executableTarget(
            name: "OpenPaste",
            dependencies: [
                .product(name: "FirebaseAnalyticsCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseCore", package: "firebase-ios-sdk")
            ],
            path: "Sources",
            exclude: openPasteTesting ? [] : testOnlySources,
            swiftSettings: openPasteTesting ? [.define("OPENPASTE_TESTING")] : [],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"), .linkedFramework("ApplicationServices"),
                .linkedFramework("LinkPresentation"), .linkedFramework("MapKit"),
                .linkedFramework("Vision"), .linkedFramework("WebKit"),
                .linkedFramework("Quartz"),
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-Xlinker", "-ObjC"])
            ]
        )
    ]
)
