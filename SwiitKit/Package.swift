// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SwiitKit",
    platforms: [.macOS(.v14)],
    products: [
        // Dynamic so the shell and every compiled plugin share one copy of
        // SwiitKit's types; a static copy per binary would make them distinct.
        .library(name: "SwiitKit", type: .dynamic, targets: ["SwiitKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        .target(
            name: "SwiitKit",
            dependencies: ["SwiitKitMacros"],
            swiftSettings: [
                // Keeps the ABI resilient, so SwiitKit can grow without
                // breaking plugins that were built against an older version.
                .unsafeFlags(["-enable-library-evolution"]),
            ]
        ),
        // `@SwiitExport` and `@SwiitObject`, run by the compiler when a
        // plugin is built.
        .macro(
            name: "SwiitKitMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .testTarget(name: "SwiitKitTests", dependencies: ["SwiitKit"]),
    ]
)
