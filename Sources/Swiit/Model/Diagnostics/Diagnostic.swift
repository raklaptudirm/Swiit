import Foundation
import SwiftSyntax
import Synchronization

/// What went wrong in a run, as a value: what kind of failure it was, the message the host would
/// print, and where in the source it is when that is known. What a kind carries is what that kind
/// has: only a run-time failure has a thrown value for a script to catch, and only a syntax error
/// can be a program that is not finished.
public struct Diagnostic: Error, CustomStringConvertible, Equatable, Sendable {
    public var message: String
    public var kind: Kind
    /// Where it is in the source: the statement a type or run-time error is in, the token a syntax
    /// error is at.
    public var range: SourceRange?

    public enum Kind: Sendable, Equatable {
        /// A syntax error. `isIncomplete`: the source ends too soon, and more of it may make it a
        /// program (a prompt asks for another line).
        case syntax(isIncomplete: Bool)
        case type
        /// A failure a script's `catch` sees, from the language or from a host function.
        case runtime(Failure)
        /// A failure that ends the run, which a script's `catch` does not see and its `defer`s
        /// run for: a failed `try!`, or a host function ending the script (a shell's `exit`).
        case fatal(Failure)
        /// A limit of the run (`Limits`) was reached.
        case limit
        case cancelled

        public static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case (.syntax(let a), .syntax(let b)): a == b
            case (.type, .type), (.limit, .limit), (.cancelled, .cancelled): true
            case (.runtime(let a), .runtime(let b)), (.fatal(let a), .fatal(let b)): a == b
            default: false
            }
        }
    }

    /// What a failure that ran has beyond its message.
    public struct Failure: Sendable, Equatable {
        /// What a script's `catch` binds.
        public var thrown: Thrown
        /// Who raised it.
        public var origin: Origin
        /// The functions it came out of, innermost first, with where each was called.
        public var calls: [Call]

        public init(
            thrown: Thrown = .message,
            origin: Origin = .language,
            calls: [Call] = []
        ) {
            self.thrown = thrown
            self.origin = origin
            self.calls = calls
        }

        public enum Thrown: Sendable, Equatable {
            /// An `Error` whose description is the message.
            case message
            /// A value the host built: a struct with the failure's fields.
            case value(Value)
        }

        public enum Origin: Sendable, Equatable {
            /// The language: division by zero, an index out of range.
            case language
            /// A host function, with nothing of its own attached.
            case host
            /// A host function, with an error of its own, which the host reads back (a status, a
            /// stop it asked for).
            case hostError(any Error)

            public static func == (lhs: Origin, rhs: Origin) -> Bool {
                switch (lhs, rhs) {
                case (.language, .language), (.host, .host): true
                case (.hostError(let a), .hostError(let b)): "\(a)" == "\(b)"
                default: false
                }
            }
        }

        public static func == (lhs: Failure, rhs: Failure) -> Bool {
            lhs.thrown == rhs.thrown && lhs.origin == rhs.origin
        }
    }

    /// A function a run-time error came out of, and where it was called.
    public struct Call: Sendable, Equatable {
        public var function: String
        public var site: SourceRange?

        public init(function: String, site: SourceRange?) {
            self.function = function
            self.site = site
        }
    }

    public init(kind: Kind, message: String, range: SourceRange? = nil) {
        self.kind = kind
        self.message = message
        self.range = range
    }

    /// How a host function fails so a script can see it: the message is what is reported, and a
    /// script's `catch` binds an `Error` of it, or `thrown` when there is more to say. `cause` is
    /// the host's own error, for the host to read back.
    public static func runtime(
        _ message: String,
        thrown: Value? = nil,
        cause: (any Error)? = nil
    ) -> Diagnostic {
        Diagnostic(
            kind: .runtime(
                Failure(
                    thrown: thrown.map { .value($0) } ?? .message,
                    origin: cause.map { .hostError($0) } ?? .host
                )
            ),
            message: message
        )
    }

    /// How a host function ends the run: a script's `catch` and `try?` let it go by, its `defer`s
    /// run, and it reaches the host as this diagnostic.
    public static func fatal(_ message: String, cause: (any Error)? = nil) -> Diagnostic {
        Diagnostic(
            kind: .fatal(Failure(origin: cause.map { .hostError($0) } ?? .host)),
            message: message
        )
    }

    /// What a failure that ran has, for a kind that can: nil for the others.
    public var failure: Failure? {
        switch kind {
        case .runtime(let failure), .fatal(let failure): failure
        default: nil
        }
    }

    public static func == (lhs: Diagnostic, rhs: Diagnostic) -> Bool {
        lhs.kind == rhs.kind && lhs.message == rhs.message && lhs.range == rhs.range
    }

    public var description: String {
        range.map { "line \($0.start.line): \(message)" } ?? message
    }

    /// How a diagnostic is styled, for a host that shows it on a terminal: the escape for each
    /// character of a source text, what the frame of the excerpt and the marks are written in,
    /// and what ends a style.
    public struct Style: Sendable {
        /// Plain ANSI: the frame in bold blue, the marks in bold red, the source as it is.
        public static let ansi = Style(
            source: { Array(repeating: nil, count: $0.count) },
            frame: { "\u{1B}[1;34m\($0)\u{1B}[0m" },
            mark: { "\u{1B}[1;31m\($0)\u{1B}[0m" },
            reset: "\u{1B}[0m"
        )

        public var source: @Sendable (String) -> [String?]
        public var frame: @Sendable (String) -> String
        public var mark: @Sendable (String) -> String
        public var reset: String

        public init(
            source: @escaping @Sendable (String) -> [String?],
            frame: @escaping @Sendable (String) -> String,
            mark: @escaping @Sendable (String) -> String,
            reset: String
        ) {
            self.source = source
            self.frame = frame
            self.mark = mark
            self.reset = reset
        }
    }

    /// The diagnostic as a compiler shows one: what is wrong, then the line of the source it is in,
    /// with the place marked. `source` is the text that was run; `path` names it, if it came from a
    /// file. `style`, if given, makes the result styled: the source in the colors it has where it
    /// is written, the marks and places in their own.
    public func rendered(in source: String, path: String? = nil, color: Bool = false) -> String {
        rendered(in: source, path: path, style: color ? .ansi : nil)
    }

    /// As above, styled as a host says (a host's syntax highlighting).
    public func rendered(in source: String, path: String? = nil, style: Style?) -> String {
        // A syntax error's own text says its line, which the excerpt shows.
        var text = message
        if let match = text.range(of: #" \(line \d+\)$"#, options: .regularExpression) {
            text.removeSubrange(match)
        }
        let heading: String
        if case .syntax = kind {
            heading = "syntax error: " + text
        } else {
            heading = "error: " + text
        }
        let place = range
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let styles = style?.source(normalized)
        guard let place,
            let first = Diagnostic.excerpt(
                of: place,
                in: normalized,
                path: path,
                styles: styles,
                style: style
            )
        else { return heading }
        var result = heading + "\n" + first
        // Where the functions it came out of were called from.
        for call in failure?.calls ?? [] {
            guard let site = call.site,
                let shown = Diagnostic.excerpt(
                    of: site,
                    in: normalized,
                    path: path,
                    styles: styles,
                    style: style
                )
            else { continue }
            let label = style?.frame("note:") ?? "note:"
            result += "\n\(label) in '\(call.function)', called from here\n" + shown
        }
        return result
    }

    /// A line of the source with a range in it marked, and where it is.
    static func excerpt(
        of place: SourceRange,
        in source: String,
        path: String?,
        styles: [String?]? = nil,
        style: Style? = nil
    ) -> String? {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        let line = place.start.line
        guard line >= 1, line <= lines.count else { return nil }
        let shown = String(lines[line - 1])
        let characters = Array(shown)
        // A column counts UTF-8 bytes, as SwiftSyntax's do; the line is marked in characters.
        func index(ofColumn column: Int) -> Int {
            var bytes = 0
            var index = 0
            while index < characters.count, bytes < column - 1 {
                bytes += String(characters[index]).utf8.count
                index += 1
            }
            return index
        }
        // From the start column to the end of the range, or of the line if it goes on; a whole-line
        // mark is the line's text.
        var from = index(ofColumn: place.start.column)
        var to = place.end.line == line ? index(ofColumn: place.end.column) : characters.count
        if place.start.column == 1, place.end.column == 1, place.end.line == line {
            from = characters.firstIndex { $0 != " " && $0 != "\t" } ?? 0
            to = characters.count
        }
        from = min(from, characters.count)
        to = min(max(to, from + 1), max(characters.count, from + 1))
        let number = String(line)
        let gutter = String(repeating: " ", count: number.count)
        let indent = characters.prefix(from).map { $0 == "\t" ? "\t" : " " }.joined()
        let marks = String(repeating: "^", count: max(to - from, 1))
        let location = (path.map { "\($0):" } ?? "") + "\(line):\(from + 1)"
        func frame(_ text: String) -> String { style?.frame(text) ?? text }
        // The line in the colors it has where it is written: the styles are by character of the
        // whole source.
        var body = shown
        if let styles {
            let before = lines[..<(line - 1)].reduce(0) { $0 + $1.count + 1 }
            body = ""
            var current: String?
            for (index, character) in characters.enumerated() {
                let escape = before + index < styles.count ? styles[before + index] : nil
                if escape != current {
                    if current != nil { body += style?.reset ?? "" }
                    if let escape { body += escape }
                    current = escape
                }
                body.append(character)
            }
            if current != nil { body += style?.reset ?? "" }
        }
        return
            "\(gutter)\(frame("-->")) \(location)\n\(gutter) \(frame("|"))\n\(frame(number + " |")) \(body)\n\(gutter) \(frame("|")) \(indent)\((style?.mark(marks) ?? marks))"
    }
}
