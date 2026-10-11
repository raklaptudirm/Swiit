import Foundation

/// Markdown's inline syntax, as a description is written in: `code`,
/// **strong**, _emphasis_ and [links](url), with a backslash to write one of
/// those characters as itself. Read here, not by Foundation, which has no
/// Markdown on Linux; the styles are `DisplayStyle`'s, so what's built is the
/// same text everywhere. Anything else, `<dir>` and `[Element]` included, is
/// the words it is.
struct InlineMarkdown {
    let chars: [Character]

    init(_ chars: [Character]) {
        self.chars = chars
    }

    /// The text of `range`, its pieces in their styles, and anything
    /// unstyled in `style`: the style of what it's inside.
    func parse(_ range: Range<Int>, style: DisplayStyle?) -> AttributedString {
        var result = AttributedString()
        var plain = ""
        func flush() {
            if !plain.isEmpty { result.append(AttributedString(plain, style)); plain = "" }
        }
        var i = range.lowerBound
        while i < range.upperBound {
            let c = chars[i]
            // `\*`: the character itself.
            if c == "\\", i + 1 < range.upperBound, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                plain.append(chars[i + 1])
                i += 2
            } else if c == "`", let (content, next) = codeSpan(at: i, in: range) {
                flush()
                result.append(AttributedString(content, .variable))
                i = next
            } else if c == "*" || c == "_", let (inner, next, emphasis) = emphasis(at: i, in: range) {
                flush()
                result.append(parse(inner, style: emphasis == 2 ? .bold : .italic))
                i = next
            } else if c == "[", let (inner, next) = link(at: i, in: range) {
                flush()
                result.append(parse(inner, style: style ?? .underline))
                i = next
            } else {
                plain.append(c)
                i += 1
            }
        }
        flush()
        return result
    }

    /// How many of `c` are in a row from `i`.
    private func run(of c: Character, at i: Int, before end: Int) -> Int {
        var n = 0
        while i + n < end, chars[i + n] == c { n += 1 }
        return n
    }

    /// A code span: a run of backticks, what's between it and the next run
    /// of as many, with one space off each end if it has one on both.
    private func codeSpan(at i: Int, in range: Range<Int>) -> (String, Int)? {
        let n = run(of: "`", at: i, before: range.upperBound)
        var j = i + n
        while j < range.upperBound {
            if chars[j] == "`" {
                let m = run(of: "`", at: j, before: range.upperBound)
                if m == n {
                    var content = String(chars[(i + n)..<j])
                    if content.count > 1, content.hasPrefix(" "), content.hasSuffix(" "), content.contains(where: { $0 != " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    return (content, j + n)
                }
                j += m
            } else {
                j += 1
            }
        }
        return nil
    }

    /// Strong (`**x**`, `__x__`) or emphasis (`*x*`, `_x_`): the opener
    /// runs into a word and the closer out of one; an underscore inside a
    /// word is just an underscore.
    private func emphasis(at i: Int, in range: Range<Int>) -> (inner: Range<Int>, next: Int, strength: Int)? {
        let c = chars[i]
        let n = run(of: c, at: i, before: range.upperBound)
        guard n <= 2, i + n < range.upperBound, !chars[i + n].isWhitespace else { return nil }
        if c == "_", i > range.lowerBound, chars[i - 1].isLetter || chars[i - 1].isNumber { return nil }
        var j = i + n
        while j < range.upperBound {
            if chars[j] == "\\" {
                j += 2
            } else if chars[j] == "`", let (_, next) = codeSpan(at: j, in: range) {
                j = next
            } else if chars[j] == c {
                let m = run(of: c, at: j, before: range.upperBound)
                let after = j + m
                let intraword = c == "_" && after < range.upperBound && (chars[after].isLetter || chars[after].isNumber)
                if m == n, !chars[j - 1].isWhitespace, !intraword, j > i + n { return ((i + n)..<j, after, n) }
                j += m
            } else {
                j += 1
            }
        }
        return nil
    }

    /// A link: `[text](url)`, the text of it, with the address left out.
    private func link(at i: Int, in range: Range<Int>) -> (inner: Range<Int>, next: Int)? {
        var depth = 0
        var j = i
        while j < range.upperBound {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "[" { depth += 1 }
            if chars[j] == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            j += 1
        }
        guard j + 1 < range.upperBound, chars[j] == "]", chars[j + 1] == "(" else { return nil }
        var k = j + 2
        var parentheses = 1
        while k < range.upperBound {
            if chars[k] == "(" { parentheses += 1 }
            if chars[k] == ")" {
                parentheses -= 1
                if parentheses == 0 { return ((i + 1)..<j, k + 1) }
            }
            k += 1
        }
        return nil
    }
}
