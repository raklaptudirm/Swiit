import Foundation
import SwishKit

/// How `help` is colored: with the roles `DisplayStyle` names, the colors the
/// highlighter gives the same things, so a signature reads as it would in code.
@_spi(Shell) public enum HelpStyle {
    /// A section's title.
    @_spi(Shell) public static func heading(_ title: String) -> AttributedString {
        AttributedString(joining: [.init(title, .label)])
    }

    /// A hand-written usage (a shell builtin's): `--name`, `-a`, `<value>` and
    /// the rest, each colored as what it is, the command's name first. A
    /// function's usage is built from its parameters instead.
    @_spi(Shell) public static func usage(_ text: String) -> [AttributedString] {
        var segments: [AttributedString] = []
        var first = true
        for (index, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { segments.append(.init(" ")) }
            segments += usageWord(String(word), isName: first && !word.isEmpty)
            if !word.isEmpty { first = false }
        }
        return segments
    }

    private static func usageWord(_ word: String, isName: Bool) -> [AttributedString] {
        if isName { return [.init(word, .command)] }
        // Brackets and bars around a flag or a placeholder stay plain.
        var segments: [AttributedString] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let style: DisplayStyle? = current.hasPrefix("-") ? .flag : current.hasPrefix("<") ? .variable : nil
            segments.append(.init(current, style))
            current = ""
        }
        for c in word {
            if "[]|".contains(c) {
                flush()
                segments.append(.init(String(c)))
            } else {
                current.append(c)
            }
        }
        flush()
        return segments
    }
}

extension AttributedString {
    /// The width it takes on a line.
    @_spi(Shell) public var width: Int { plain.count }
}
