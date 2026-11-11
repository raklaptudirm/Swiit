import Foundation

// AttributedString as a host type: what a script reads of rich text.

extension AttributedString {
    /// What a script can read of rich text: its words, and how they show (as its words, plain, or with
    /// the terminal's escapes for each style).
    static let native = HostTypeBuilder<AttributedString>("AttributedString")
        .property("text", \.plain)
        .property("plain", \.plain)
        .property("description", \.plain)
        .property("debugDescription", \.plain)
        .property("colored", \.colored)
}
