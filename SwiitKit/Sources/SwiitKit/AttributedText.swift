import Foundation

// Text with styles is Foundation's `AttributedString`: what Swift uses for
// it, so `help`, and anything else that shows text with emphasis, hands
// Swiit a standard type. Foundation alone has no colors (they're in AppKit,
// UIKit and SwiftUI), so the shell's own are one attribute: a style by what
// the text is, which the terminal turns into a color when it's shown. (Nor
// does Foundation on Linux parse Markdown, so documentation's is read here.)

/// The style a run of text is in: `DisplayStyle`'s roles (a keyword, a type,
/// a flag…), not a color, so what a color is, or whether there is one, is
/// decided when it's shown.
public enum DisplayStyleAttribute: AttributedStringKey {
    public typealias Value = DisplayStyle
    public static let name = "swiit.displayStyle"
}

extension AttributeScopes {
    public struct SwiitAttributes: AttributeScope {
        public let displayStyle: DisplayStyleAttribute
    }

    public var swiit: SwiitAttributes.Type { SwiitAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SwiitAttributes, T>) -> T {
        self[T.self]
    }
}

extension AttributedString {
    /// Text in a style, or plain if there's none.
    public init(_ text: String, _ style: DisplayStyle?) {
        self.init(text)
        if let style { self.swiit.displayStyle = style }
    }

    /// Pieces one after the other.
    public init(joining pieces: [AttributedString]) {
        self.init()
        for piece in pieces { append(piece) }
    }

    /// Without the styles.
    public var plain: String {
        String(characters)
    }

    /// Text written in Markdown, as documentation is: its code, strong text,
    /// emphasis and links as styles, which show where there are colors, and
    /// the plain words anywhere else. Only the inline syntax, which is what a
    /// description is made of; see `InlineMarkdown`.
    public init(documentation text: String) {
        self = InlineMarkdown(Array(text)).parse(0..<text.count, style: nil)
    }

    /// With the terminal's escapes for each style.
    public var colored: String {
        var result = ""
        for run in runs {
            let text = String(self[run.range].characters)
            if let style = run.swiit.displayStyle, !text.isEmpty {
                result += style.escape + text + DisplayStyle.reset
            } else {
                result += text
            }
        }
        return result
    }

    /// As a String: with the terminal's escapes if `styled`.
    public func rendered(_ styled: Bool) -> String {
        styled ? colored : plain
    }
}

extension AttributedString: StandsForText, SwiitDisplayed {
    public var text: String { plain }
    public var swiitDescription: String { plain }
    public var swiitColored: String? { colored }
}

extension Value {
    /// Text with styles, held as the Swift value it is.
    public static func attributed(_ text: AttributedString) -> Value {
        SwiftValue.make(text, as: "AttributedString")
    }
}
