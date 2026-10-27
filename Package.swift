// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "shelf",
    // Verified on macOS 26 only. See docs/DECISIONS.md D8, D9 and D14.
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic: icons, the layout memory, the drift planner, the check.
        .target(name: "ShelfCore"),
        // The app and the CLI in one binary.
        .executableTarget(name: "shelf", dependencies: ["ShelfCore"]),
        // Tests without XCTest (CLT-only machine): `swift run ShelfSelfTest`.
        .executableTarget(name: "ShelfSelfTest", dependencies: ["ShelfCore"]),
        .executableTarget(name: "ShelfDisplayTest", dependencies: ["ShelfCore"]),
        .executableTarget(name: "ShelfRecoveryTest", dependencies: ["ShelfCore"]),
        .executableTarget(name: "ShelfPersistenceTest", dependencies: ["ShelfCore"]),
        // A fake app whose menu bar icon comes and goes, like a timer app. Used by Test 1.
        .executableTarget(name: "ShelfChurn"),
    ]
)
