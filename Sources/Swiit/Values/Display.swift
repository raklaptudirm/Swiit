import Foundation

/// How a type says it's shown: the styles and shapes the printers read.

/// A style for text: bold, dim, or a color, and the roles the host gives
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
    public static let function = DisplayStyle.green // a function's name
    public static let comment = DisplayStyle.dim // secondary text: job numbers, `nil`s, cut-off markers
    public static let label = DisplayStyle.bold // table headers, record keys, help sections
    public static let error = DisplayStyle.boldRed

    /// The terminal's escape for it, and what ends it.
    public var escape: String { "\u{1B}[\(rawValue)m" }
    public static let reset = "\u{1B}[0m"
}

extension String {
    /// `self` in `style`, if styling is on.
    public func styled(_ style: DisplayStyle?, _ enabled: Bool = true) -> String {
        guard enabled, let style, !isEmpty else { return self }
        return style.escape + self + DisplayStyle.reset
    }
}

/// A Swift type that shows in Swiit other than as its `description`: a date
/// in local time, to the second.
public protocol SwiitDisplayed {
    var swiitDescription: String { get }
    var swiitDebugDescription: String { get }
}

extension SwiitDisplayed {
    public var swiitDebugDescription: String { swiitDescription }
}
