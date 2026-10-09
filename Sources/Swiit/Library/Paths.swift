import SwishKit
import SystemPackage

// How a path shows in Swish: its text, unquoted, in the path color, unlike
// a String.

extension FilePath: @retroactive SwishDisplayed {
    public var swishDescription: String { string }
    /// As Swift writes it, quoted: the text is for showing, this is for code.
    public var swishDebugDescription: String { String(reflecting: self) }
    public var swishShape: DisplayShape { DisplayShape(role: .path) }
}

extension FilePath.Component: @retroactive SwishDisplayed {
    public var swishDescription: String { string }
    /// As Swift writes it, quoted: the text is for showing, this is for code.
    public var swishDebugDescription: String { String(reflecting: self) }
    public var swishShape: DisplayShape { DisplayShape(role: .path) }
}
