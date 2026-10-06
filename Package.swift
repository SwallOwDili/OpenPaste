// swift-tools-version:5.9
import PackageDescription

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
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"), .linkedFramework("ApplicationServices"),
                .linkedFramework("LinkPresentation"), .linkedFramework("MapKit"),
                .linkedFramework("Vision"), .linkedFramework("WebKit"),
                .linkedFramework("Quartz"), .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
