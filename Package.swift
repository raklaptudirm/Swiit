// swift-tools-version: 6.0
import PackageDescription

// The interpreter. It knows nothing of the shell: Swish is a client of it.
let package = Package(
    name: "Swiit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Swiit", targets: ["Swiit"]),
        // Plain Swift the interpreter bridges (`Flow`, the formatters); the
        // shell's own library builds on it.
        .library(name: "SwiitStandardLibrary", targets: ["SwiitStandardLibrary"]),
        // Reads Swift's symbol graphs and writes the glue that bridges them
        // (`run bridge`); not part of the interpreter.
        .executable(name: "swiit-bridge", targets: ["SwiitBridge"]),
    ],
    dependencies: [
        // A separate package so a host links SwiitKit as a dylib (products of
        // the same package would be linked statically into the executable).
        .package(path: "../SwiitKit"),
        // FilePath, until the standard library's (SE-0529) ships; swift-system's
        // then becomes a typealias for it, keeping the members added here.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        .executableTarget(name: "SwiitBridge"),
        // The interpreter's own functions, written in Swift: `swiit-bridge`
        // reads their declarations and Swiit calls them.
        .target(
            name: "SwiitStandardLibrary",
            dependencies: [
                .product(name: "SwiitKit", package: "SwiitKit"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/Swiit/Library"
        ),
        .target(
            name: "Swiit",
            dependencies: [
                "SwiitStandardLibrary",
                .product(name: "SwiitKit", package: "SwiitKit"),
                .product(name: "SystemPackage", package: "swift-system"),
                // Source is read by SwiftParser; the front end lowers its tree.
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            // Its standard library is a module of its own, so the generator can read it.
            exclude: ["Library"]
        ),
        // boundaries.txt and spi-surface.txt are data the boundary tests read from the source tree.
        .testTarget(name: "SwiitTests", dependencies: ["Swiit"], exclude: ["boundaries.txt", "spi-surface.txt", "programs.txt", "Goldens"]),
    ]
)
