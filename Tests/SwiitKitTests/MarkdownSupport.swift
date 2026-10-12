import Foundation
@testable import SwiitKit

// Foundation's AttributedString for the Markdown tests, in a file of its own:
// Foundation can't be imported next to Testing here.

/// Documentation text, as plain words and with the terminal's escapes.
func documentation(_ text: String) -> (plain: String, colored: String) {
    let line = AttributedString(documentation: text)
    return (line.plain, line.colored)
}
