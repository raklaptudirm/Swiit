import SwiitKit
import SystemPackage

// How a path shows in Swiit: its text, unquoted, in the path color, unlike
// a String.

extension FilePath: @retroactive SwiitDisplayed {
    public var swiitDescription: String { string }
    /// As Swift writes it, quoted: the text is for showing, this is for code.
    public var swiitDebugDescription: String { String(reflecting: self) }
    public var swiitShape: DisplayShape { DisplayShape(role: .path) }
}

extension FilePath.Component: @retroactive SwiitDisplayed {
    public var swiitDescription: String { string }
    /// As Swift writes it, quoted: the text is for showing, this is for code.
    public var swiitDebugDescription: String { String(reflecting: self) }
    public var swiitShape: DisplayShape { DisplayShape(role: .path) }
}
