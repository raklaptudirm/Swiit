import Foundation

/// How a type says it's shown: the styles and shapes the printers read.

/// A style for text: bold, dim, or a color, and the roles the shell gives
/// them, so a string or a type looks the same typed, shown and in help. Its
/// raw value is the terminal's code for it.
public enum DisplayStyle: String, Sendable {
    case bold = "1"
    case italic = "3"
    case underline = "4"
    case dim = "90"
    case red = "31"
    case green = "32"
    case yellow = "33"
    case blue = "34"
    case magenta = "35"
    case cyan = "36"
    case boldRed = "1;31"
    case boldBlue = "1;34"
    case brightMagenta = "95"
    case brightYellow = "93"

    // What each kind of thing is shown in.
    public static let keyword = DisplayStyle.magenta
    public static let string = DisplayStyle.yellow
    public static let constant = DisplayStyle.brightMagenta // numbers, true, nil
    public static let type = DisplayStyle.brightYellow
    public static let variable = DisplayStyle.cyan // a variable, a parameter's name
    public static let path = DisplayStyle.green // a FilePath, unquoted, unlike a String
    public static let command = DisplayStyle.green // a name that runs
    public static let flag = DisplayStyle.blue
    public static let comment = DisplayStyle.dim // secondary text: job numbers, `nil`s, cut-off markers
    public static let label = DisplayStyle.bold // table headers, record keys, help sections
    public static let error = DisplayStyle.boldRed

    /// The terminal's escape for it, and what ends it.
    public var escape: String { "\u{1B}[\(rawValue)m" }
    public static let reset = "\u{1B}[0m"
}

extension DisplayStyle {
    /// Whether to style what's written to `fd`: only for a terminal, and
    /// not with `NO_COLOR` set or `TERM=dumb`.
    public static func enabled(for fd: Int32) -> Bool {
        func variable(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }
        return isatty(fd) != 0 && variable("NO_COLOR").map(\.isEmpty) != false && variable("TERM") != "dumb"
    }
}

extension String {
    /// `self` in `style`, if styling is on.
    public func styled(_ style: DisplayStyle?, _ enabled: Bool = true) -> String {
        guard enabled, let style, !isEmpty else { return self }
        return style.escape + self + DisplayStyle.reset
    }
}

/// A Swift type that shows in Swiit other than as its `description`: a date
/// in local time, to the second, and to the minute in a table.
public protocol SwiitDisplayed {
    var swiitDescription: String { get }
    var swiitCell: String { get }
    var swiitDebugDescription: String { get }
    /// It with terminal color escapes, if it has colors to show: what's
    /// written to a terminal, where `swiitDescription` is for a pipe or file.
    var swiitColored: String? { get }
    /// What else the printers need to know of how it looks.
    var swiitShape: DisplayShape { get }
}

/// The facts about how a value looks that the printers need beyond its text,
/// said by its type: each is optional, and a type says only what's true of it.
public struct DisplayShape: Sendable {
    /// The style of its text in a debug form, when it's one thing: a number,
    /// a path.
    public var role: DisplayStyle?
    /// It's a number, so a column of them lines up on the right.
    public var isNumeric: Bool
    /// It has nothing to show: a command that printed nothing.
    public var isEmpty: Bool

    public init(role: DisplayStyle? = nil, isNumeric: Bool = false, isEmpty: Bool = false) {
        self.role = role
        self.isNumeric = isNumeric
        self.isEmpty = isEmpty
    }
}

extension SwiitDisplayed {
    public var swiitShape: DisplayShape { DisplayShape() }
    public var swiitCell: String { swiitDescription }
    public var swiitDebugDescription: String { swiitDescription }
    public var swiitColored: String? { nil }
}

extension Date: SwiitDisplayed {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public var swiitDescription: String { Date.formatter.string(from: self) }
    /// `2026-09-27 14:03`.
    public var swiitCell: String { String(swiitDescription.prefix(16)) }
}
