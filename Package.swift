// swift-tools-version: 6.0
import PackageDescription

// The interpreter. It knows nothing of the programs that host it.
let package = Package(
    name: "Swiit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Swiit", targets: ["Swiit"]),
        // Reads Swift's symbol graphs and writes the glue that bridges them
        // (`Scripts/bridge`); not part of the interpreter.
        .executable(name: "swiit-bridge", targets: ["SwiitBridge"]),
    ],
    dependencies: [
        // FilePath, until the standard library's (SE-0529) ships; swift-system's
        // then becomes a typealias for it, keeping the members added here.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        .executableTarget(name: "SwiitBridge"),
        .target(
            name: "Swiit",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                // Source is read by SwiftParser; the front end lowers its tree.
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            // The prelude is Swift source that is read, not compiled: it is embedded in the target.
            resources: [.embedInCode("Resources/Prelude.swift")]
        ),
        // boundaries.txt and programs.txt are data the boundary tests read from the source tree.
        .testTarget(name: "SwiitTests", dependencies: ["Swiit"], exclude: ["boundaries.txt", "programs.txt", "parity.json", "parity-NOTICE.txt", "Goldens"]),
    ]
)
