// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Homebase",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HomebaseCore", targets: ["HomebaseCore"]),
        .library(name: "HomebaseSSHSystem", targets: ["HomebaseSSHSystem"]),
        .executable(name: "HomebaseMac", targets: ["HomebaseMac"]),
        .executable(name: "homebase-probe", targets: ["HomebaseProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "HomebaseCore",
            path: "Packages/HomebaseCore/Sources/HomebaseCore"
        ),
        .target(
            name: "HomebaseSSHSystem",
            dependencies: ["HomebaseCore"],
            path: "Packages/HomebaseSSHSystem/Sources/HomebaseSSHSystem"
        ),
        .executableTarget(
            name: "HomebaseMac",
            dependencies: [
                "HomebaseCore", "HomebaseSSHSystem",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Apps/HomebaseMac",
            exclude: ["Resources/SOURCES.md"],
            sources: ["Sources/HomebaseMac"],
            resources: [.copy("Resources/themes.json")]
        ),
        .executableTarget(
            name: "HomebaseProbe",
            dependencies: ["HomebaseSSHSystem"],
            path: "Apps/HomebaseProbe/Sources/HomebaseProbe"
        ),
        .testTarget(
            name: "HomebaseSSHSystemTests",
            dependencies: ["HomebaseSSHSystem"],
            path: "Packages/HomebaseSSHSystem/Tests/HomebaseSSHSystemTests"
        ),
        .testTarget(
            name: "HomebaseCoreTests",
            dependencies: ["HomebaseCore"],
            path: "Packages/HomebaseCore/Tests/HomebaseCoreTests"
        ),
    ]
)
