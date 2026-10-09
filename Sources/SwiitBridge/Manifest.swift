import Foundation

/// The members a module's types declare on one platform. A symbol graph is
/// read on the platform it's made on, and a member can exist on one and not
/// another (Foundation's `inflected()` is macOS's), so each platform's list is
/// kept, and only what every platform declares is bridged: a member that
/// exists on one platform can't be committed to break the build on another.
/// What's listed is what's declared, not what the generator can bridge,
/// which depends on how a platform's graph is shaped.
struct Manifest: Codable {
    let platform: String
    let module: String
    /// A type's name, the kind of one of its members, and its name with its
    /// labels: `Range<TAB>swift.method<TAB>index(_:offsetBy:)`.
    let members: [String]

    /// The platform this runs on.
    static var current: String {
        #if os(Linux)
        "linux"
        #elseif os(macOS)
        "macos"
        #else
        "other"
        #endif
    }

    init(platform: String, module: String, members: [String]) {
        self.platform = platform
        self.module = module
        self.members = members
    }

    init(contentsOf path: String) throws {
        self = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// One member to a line, in order, so what changes shows as a diff.
    func write(to path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: URL(fileURLWithPath: path))
    }
}
