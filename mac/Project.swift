import Foundation
import ProjectDescription

/// The repo-root `VERSION` file is the single source of truth: CI reads it for the tag and the
/// cask, and the app's update check compares it against the latest release tag.
let appVersion: String = {
    let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("VERSION")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return version.isEmpty ? "dev" : version
}()

let project = Project(
    name: "RAWViewer",
    packages: [
        .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .upToNextMajor(from: "2.10.0")),
    ],
    settings: .settings(
        base: [
            "SWIFT_VERSION": "5",
            "SWIFT_STRICT_CONCURRENCY": "minimal",
        ]
    ),
    targets: [
        .target(
            name: "RAWViewer",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.yannickpulver.rawviewer",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": .string(appVersion),
                // CI passes `CURRENT_PROJECT_VERSION=<run number>`.
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleName": "RAW Viewer",
                "CFBundleIconFile": "AppIcon",
                "LSMinimumSystemVersion": "15.0",
                "NSHighResolutionCapable": true,
                "LSApplicationCategoryType": "public.app-category.photography",
                // Sparkle: CI attaches a one-item appcast to every release; `latest/download`
                // always points at the newest one. Compares against `CFBundleVersion`.
                "SUFeedURL": "https://github.com/yannickpulver/raw-viewer/releases/latest/download/appcast.xml",
                "SUPublicEDKey": "OHWn0kVxbxpGQaeRP99JWIEVyhOskRRuRZv5NwyzB/E=",
                "SUEnableAutomaticChecks": true,
            ]),
            sources: ["RAWViewer/Sources/**"],
            resources: ["RAWViewer/Resources/**"],
            dependencies: [.package(product: "Sparkle")],
            settings: .settings(base: [
                "SWIFT_VERSION": "5",
                "SWIFT_STRICT_CONCURRENCY": "minimal",
                "CURRENT_PROJECT_VERSION": "1",
                "ENABLE_APP_SANDBOX": "NO",
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            ])
        ),
        .target(
            name: "RAWViewerTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.yannickpulver.rawviewer.tests",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: ["RAWViewerTests/**"],
            dependencies: [.target(name: "RAWViewer")],
            settings: .settings(base: [
                "SWIFT_VERSION": "5",
                "SWIFT_STRICT_CONCURRENCY": "minimal",
            ])
        ),
    ]
)
