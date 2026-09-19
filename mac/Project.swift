import ProjectDescription

let project = Project(
    name: "RAWViewer",
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
                "CFBundleShortVersionString": "0.4.5",
                "CFBundleVersion": "1",
                "CFBundleName": "RAW Viewer",
                "CFBundleIconFile": "AppIcon",
                "LSMinimumSystemVersion": "15.0",
                "NSHighResolutionCapable": true,
                "LSApplicationCategoryType": "public.app-category.photography",
            ]),
            sources: ["RAWViewer/Sources/**"],
            resources: ["RAWViewer/Resources/**"],
            settings: .settings(base: [
                "SWIFT_VERSION": "5",
                "SWIFT_STRICT_CONCURRENCY": "minimal",
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
