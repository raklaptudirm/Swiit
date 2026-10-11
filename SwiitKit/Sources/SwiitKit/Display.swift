import Foundation

/// How a type says it's shown, so the shell has no table of its types' names:
/// which columns a table starts with, and what stands out in them.

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

/// A column a table shows, and what styles it: the value of another field
/// (or of itself), if that is a `DisplayStyled` enum, as a file's name is
/// styled by its type: `DisplayColumn("name", styledBy: "type")`; or one
/// style for all of it: `DisplayColumn("name", style: .green)`.
public struct DisplayColumn: Sendable, ExpressibleByStringLiteral {
    public let name: String
    public let styledBy: String?
    public let style: DisplayStyle?

    public init(_ name: String, styledBy: String? = nil, style: DisplayStyle? = nil) {
        self.name = name
        self.styledBy = styledBy
        self.style = style
    }

    public init(stringLiteral name: String) {
        self.init(name)
    }
}

/// How the shell's types show in a table, by the name of the type: the
/// columns of the structs that say so (`Tabular`), and how an enum's cases
/// are styled (`DisplayStyled`). A function that lays values out is lent it
/// in the `HostContext`.
public struct DisplayRegistry: Sendable {
    public var columns: [String: [DisplayColumn]]
    public var enumStyles: [String: @Sendable (String) -> DisplayStyle?]

    public init(columns: [String: [DisplayColumn]] = [:], enumStyles: [String: @Sendable (String) -> DisplayStyle?] = [:]) {
        self.columns = columns
        self.enumStyles = enumStyles
    }
}

/// A struct that says which of its fields a table shows by default, in
/// order. The rest are still there for `filter`, `select` and `get`, and
/// `table` shows every one.
public protocol Tabular {
    static var columns: [DisplayColumn] { get }
}

/// An enum whose cases stand out, by being shown in a style.
public protocol DisplayStyled {
    var displayStyle: DisplayStyle? { get }
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
    /// It's shown as a struct's fields in a debug form, `Output(text: …)`.
    public var fields: Record?

    public init(role: DisplayStyle? = nil, isNumeric: Bool = false, isEmpty: Bool = false, fields: Record? = nil) {
        self.role = role
        self.isNumeric = isNumeric
        self.isEmpty = isEmpty
        self.fields = fields
    }
}

extension Value {
    /// How it looks, beyond its text: plain for anything that doesn't say.
    public var displayShape: DisplayShape {
        if case .object(let box as SwiftValue) = self, let displayed = box.value as? any SwiitDisplayed {
            return displayed.swiitShape
        }
        return DisplayShape()
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
