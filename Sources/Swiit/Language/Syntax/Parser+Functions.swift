import Foundation
import SwishKit

extension Parser {
    // MARK: Functions and closures

    /// `method`: a struct's, which is reached through `self` rather than
    /// bound as a function.
    @_spi(Shell) public mutating func parseFunction(method: Bool = false) throws(SyntaxError) -> FunctionDecl {
        let documentation = documentation(before: pos)
        keyword("func")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'func'")
        mark(.command, from: nameStart)
        guard name != "_" else { throw SyntaxError("a function needs a name") }
        skipSpaces()
        var generics: [String: [String]] = [:]
        if peek() == "<" {
            guard prelude else { throw SyntaxError("generic functions of your own come later; Swish's builtins are generic for now") }
            generics = try parseGenericParameters()
        }
        typeParameters.append(Set(generics.keys))
        defer { typeParameters.removeLast() }
        guard peek() == "(" else { throw expected("'(' after '\(name)'") }
        let parameters = try parseParameters(named: true)
        skipSpaces()
        let throwing = parseThrows()
        var rethrowing = false
        if prelude && identifier() == "rethrows" {
            keyword("rethrows")
            skipSpaces()
            rethrowing = true
        }
        var returnType: TypeAnnotation?
        if consume("->") {
            returnType = try parseType()
            skipSpaces()
        }
        if prelude && identifier() == "where" {
            // `where Element: Comparable`
            keyword("where")
            repeat {
                skipSpaces()
                let parameter = try parseName(after: "'where'")
                skipSpaces()
                guard consume(":") else { throw expected("':' in a where clause") }
                generics[parameter, default: []] += try parseConformances()
                skipSpaces()
            } while consume(",")
        }
        // In the prelude, a builtin's body is in Swift.
        if prelude && peek() != "{" {
            return FunctionDecl(
                name: name, parameters: parameters, returnType: returnType, body: Program(statements: []),
                documentation: documentation, isThrowing: throwing, isRethrowing: rethrowing, generics: generics
            )
        }
        guard consume("{") else { throw expected("'{'") }
        // Bound before the body is parsed, so the function can call itself.
        if !method { scopes[scopes.count - 1][name] = .function }
        let (body, _) = try parseFunctionBody(parameters: parameters, anonymous: false)
        return FunctionDecl(
            name: name, parameters: parameters, returnType: returnType, body: body, documentation: documentation,
            isThrowing: throwing, names: lastBodyNames
        )
    }

    /// `<T, V: Comparable>`: type parameters and their constraints.
    @_spi(Shell) public mutating func parseGenericParameters() throws(SyntaxError) -> [String: [String]] {
        pos += 1
        var generics: [String: [String]] = [:]
        repeat {
            skipSpaces()
            let start = pos
            let name = try parseName(after: "'<'")
            mark(.type, from: start)
            skipSpaces()
            generics[name] = consume(":") ? try parseConformances() : []
            skipSpaces()
        } while consume(",")
        guard consume(">") else { throw expected("'>'") }
        skipSpaces()
        return generics
    }

    /// `extension Sequence { … }`: methods every sequence has, with its
    /// items' type as `Element`.
    @_spi(Shell) public mutating func parseExtension() throws(SyntaxError) -> Statement {
        keyword("extension")
        skipSpaces()
        let name = try parseName(after: "'extension'")
        guard name == "Sequence" else { throw SyntaxError("only Sequence can be extended, for now") }
        skipSpaces()
        guard consume("{") else { throw expected("'{'") }
        typeParameters.append(["Element"])
        defer { typeParameters.removeLast() }
        var methods: [FunctionDecl] = []
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            guard identifier() == "func" else { throw expected("'func'") }
            var method = try parseFunction(method: true)
            method.generics["Element", default: []] += []
            methods.append(method)
        }
        return .extensionDecl(name: name, methods: methods)
    }

    /// `throws` after a signature's parameters.
    @_spi(Shell) public mutating func parseThrows() -> Bool {
        guard identifier() == "throws" else { return false }
        keyword("throws")
        skipSpaces()
        return true
    }

    /// The `///` comment lines directly above the line starting at `index`.
    @_spi(Shell) public func documentation(before index: Int) -> Documentation? {
        var lineStart = index
        while lineStart > 0 && (chars[lineStart - 1] == " " || chars[lineStart - 1] == "\t") { lineStart -= 1 }
        guard lineStart > 0 && chars[lineStart - 1] == "\n" else { return nil }

        var lines: [String] = []
        var end = lineStart - 1 // The newline ending the line above.
        while end >= 0 {
            var start = end
            while start > 0 && chars[start - 1] != "\n" { start -= 1 }
            let line = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("///") else { break }
            var text = line.dropFirst(3)
            if text.first == " " { text = text.dropFirst() }
            lines.insert(String(text), at: 0)
            end = start - 1
        }
        guard !lines.isEmpty else { return nil }

        var summary: [String] = []
        var parameters: [String: String] = [:]
        for line in lines {
            if line.hasPrefix("- Parameter "), let colon = line.firstIndex(of: ":") {
                let name = line[line.index(line.startIndex, offsetBy: 12)..<colon].trimmingCharacters(in: .whitespaces)
                parameters[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                summary.append(line)
            }
        }
        return Documentation(
            summary: summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            parameters: parameters
        )
    }

    /// A closure, positioned after its opening brace: `{ x, y in … }`,
    /// `{ (x: Int) -> Int in … }`, or `{ $0 * 2 }`.
    @_spi(Shell) public mutating func parseClosure() throws(SyntaxError) -> ClosureLiteral {
        var named: (parameters: [Parameter], returnType: TypeAnnotation?)?
        let beforeHead = self
        do {
            named = try parseClosureHead()
        } catch {
            self = beforeHead
        }
        let (body, arity) = try parseFunctionBody(parameters: named?.parameters ?? [], anonymous: named == nil)
        let parameters = named?.parameters ?? (0..<arity).map { Parameter(label: nil, name: "$\($0)") }
        return ClosureLiteral(parameters: parameters, returnType: named?.returnType, body: body, names: lastBodyNames)
    }

    @_spi(Shell) public mutating func parseClosureHead() throws(SyntaxError) -> ([Parameter], TypeAnnotation?) {
        skipSpaces(newlines: true)
        var parameters: [Parameter] = []
        if peek() == "(" {
            parameters = try parseParameters(named: false)
        } else {
            while true {
                parameters.append(Parameter(label: nil, name: try parseName(after: "'{'")))
                skipSpaces()
                guard consume(",") else { break }
                skipSpaces()
            }
            try validate(parameters)
        }
        skipSpaces()
        var returnType: TypeAnnotation?
        if consume("->") {
            returnType = try parseType()
            skipSpaces()
        }
        guard identifier() == "in" else { throw expected("'in'") }
        keyword("in")
        return (parameters, returnType)
    }

    /// Statements up to the closing brace, whose opening brace is already
    /// consumed, in a new function scope. Returns the `$n` arity for
    /// anonymous closures.
    @_spi(Shell) public mutating func parseFunctionBody(
        parameters: [Parameter], anonymous: Bool
    ) throws(SyntaxError) -> (Program, Int) {
        let saved = (loopDepth, bracketDepth, conditionDepth, tryDepth, switchDepth)
        loopDepth = 0
        bracketDepth = 0
        conditionDepth = 0
        tryDepth = 0
        switchDepth = 0
        functionDepth += 1
        var names: [String: NameKind] = [:]
        for parameter in parameters where parameter.name != "_" {
            names[parameter.name] = .variable
        }
        scopes.append(names)
        anonymousArity.append(anonymous ? 0 : nil)
        defer {
            (loopDepth, bracketDepth, conditionDepth, tryDepth, switchDepth) = saved
            functionDepth -= 1
            scopes.removeLast()
            anonymousArity.removeLast()
        }
        namesUsed.append([])
        let body: Program
        do {
            body = try parseProgram(until: "}")
        } catch {
            namesUsed.removeLast()
            throw error
        }
        // What an inner body mentions, the outer one must keep too.
        let mentioned = namesUsed.removeLast()
        if !namesUsed.isEmpty { namesUsed[namesUsed.count - 1].formUnion(mentioned) }
        lastBodyNames = NamesUsed(names: mentioned)
        pos += 1
        return (body, anonymousArity.last! ?? 0)
    }

    /// `(label name: Type = default, …)` for functions (`named`), or
    /// `(name: Type, …)` for closures, where types are optional.
    @_spi(Shell) public mutating func parseParameters(named: Bool) throws(SyntaxError) -> [Parameter] {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var parameters: [Parameter] = []
        skipSpaces()
        if !consume(")") {
            while true {
                parameters.append(try parseParameter(named: named))
                skipSpaces()
                if consume(")") { break }
                guard consume(",") else { throw expected("',' or ')'") }
                skipSpaces()
            }
        }
        try validate(parameters)
        return parameters
    }

    @_spi(Shell) public mutating func parseParameter(named: Bool) throws(SyntaxError) -> Parameter {
        var isInput = false
        var shortFlag: Character?
        while named && peek() == "@" {
            let attributeStart = pos
            pos += 1
            guard let attribute = identifier() else { throw expected("an attribute name after '@'") }
            pos += attribute.count
            mark(.keyword, from: attributeStart)
            switch attribute {
            case "input":
                isInput = true
            case "flag":
                skipSpaces()
                guard consume("(") else { throw expected("'(' after '@flag'") }
                skipSpaces()
                guard peek() == "\"", let letter = peek(1), letter.isLetter || Parser.isDigit(letter), peek(2) == "\"" else {
                    throw SyntaxError("@flag needs a single letter or digit, like @flag(\"n\")")
                }
                mark(.string, from: pos, to: pos + 3)
                pos += 3
                skipSpaces()
                guard consume(")") else { throw expected("')'") }
                shortFlag = letter
            default:
                throw SyntaxError("unknown attribute '@\(attribute)'")
            }
            skipSpaces()
        }

        let first = try parseName(after: "'('")
        skipSpaces()
        var parameter = Parameter(label: first == "_" ? nil : first, name: first, isInput: isInput, shortFlag: shortFlag)
        if named {
            if let second = identifier() {
                pos += second.count
                skipSpaces()
                guard !Parser.keywords.contains(second) else { throw SyntaxError("'\(second)' is a keyword") }
                parameter.name = second
            } else if first == "_" {
                throw expected("a parameter name after '_'")
            }
        } else {
            parameter.label = nil
        }

        if consume(":") {
            parameter.type = try parseType()
            parameter.variadic = consume("...")
            skipSpaces()
        } else if named {
            throw expected("':' and a type for '\(parameter.name)'")
        }

        if named && peek() == "=" && peek(1) != "=" {
            pos += 1
            parameter.defaultValue = try parseExpression()
        }
        return parameter
    }

    @_spi(Shell) public func validate(_ parameters: [Parameter]) throws(SyntaxError) {
        var seen: Set<String> = []
        var shortFlags: Set<Character> = []
        if parameters.filter(\.isInput).count > 1 {
            throw SyntaxError("only one parameter can be @input")
        }
        for (index, parameter) in parameters.enumerated() {
            if parameter.isInput && parameter.variadic {
                throw SyntaxError("an @input parameter can't be variadic; use a list type for the whole stream")
            }
            if let flag = parameter.shortFlag {
                guard parameter.label != nil else { throw SyntaxError("@flag needs a labeled parameter") }
                guard shortFlags.insert(flag).inserted else { throw SyntaxError("duplicate short flag -\(flag)") }
            }
            if parameter.name != "_" && !seen.insert(parameter.name).inserted {
                throw SyntaxError("duplicate parameter '\(parameter.name)'")
            }
            // As in Swift, what follows a variadic must have a label, so it's
            // clear where the variadic ends.
            if parameter.variadic && index + 1 < parameters.count && parameters[index + 1].label == nil {
                throw SyntaxError("the parameter after a variadic needs a label")
            }
            if parameter.variadic && parameter.defaultValue != nil {
                throw SyntaxError("a variadic parameter can't have a default value")
            }
        }
    }

    @_spi(Shell) public mutating func parseType() throws(SyntaxError) -> TypeAnnotation {
        let type = try parseNonOptionalType()
        return consume("?") ? .optional(type) : type
    }

    @_spi(Shell) public mutating func parseNonOptionalType() throws(SyntaxError) -> TypeAnnotation {
        skipSpaces()
        if consume("[") {
            let element = try parseType()
            skipSpaces()
            if consume(":") {
                let value = try parseType()
                skipSpaces()
                guard consume("]") else { throw expected("']'") }
                return .dictionary(element, value)
            }
            guard consume("]") else { throw expected("']'") }
            return .list(element)
        }
        if consume("(") {
            // A tuple, `(name: String, Int)`; or a function's parameters,
            // `(Int) -> Bool`; or just parentheses, `(Int)`.
            var elements: [TypeAnnotation.TupleElement] = []
            skipSpaces()
            if !consume(")") {
                while true {
                    skipSpaces()
                    var label: String?
                    if let word = identifier(), peek(word.count) == ":" {
                        label = word
                        pos += word.count + 1
                    }
                    elements.append(.init(label: label, type: try parseType()))
                    skipSpaces()
                    if consume(")") { break }
                    guard consume(",") else { throw expected("',' or ')'") }
                }
            }
            let afterParentheses = (pos, spans.count)
            skipSpaces()
            var throwing = false
            if identifier() == "throws" {
                keyword("throws")
                throwing = true
                skipSpaces()
            }
            if consume("->") {
                guard elements.allSatisfy({ $0.label == nil }) else {
                    throw SyntaxError("a function type's parameters have no labels")
                }
                return .functionType(elements.map(\.type), try parseType(), throws: throwing)
            }
            if throwing { throw expected("'->' after 'throws'") }
            rewind(to: afterParentheses)
            if elements.isEmpty { return .void }
            if elements.count == 1 && elements[0].label == nil { return elements[0].type }
            return .tuple(elements)
        }
        guard var name = identifier() else { throw expected("a type") }
        mark(.type, from: pos, to: pos + name.count)
        pos += name.count
        // A nested bridged type: `FilePath.Component`.
        while peek() == ".", let inner = identifier(at: pos + 1), Bridge.types["\(name).\(inner)"] != nil {
            mark(.type, from: pos + 1, to: pos + 1 + inner.count)
            pos += 1 + inner.count
            name += "." + inner
        }
        if typeParameters.contains(where: { $0.contains(name) }) { return .parameter(name) }
        if name == "KeyPath" && consume("<") {
            let root = try parseType()
            skipSpaces()
            guard consume(",") else { throw expected("',' in KeyPath<Root, Value>") }
            let value = try parseType()
            skipSpaces()
            guard consume(">") else { throw expected("'>'") }
            return .keyPath(root, value)
        }
        if peek() == "<", let generic = Bridge.types[name], !generic.genericParameters.isEmpty {
            // `Set<Int>`, `Array<Int>`, `Dictionary<String, Int>`.
            pos += 1
            var arguments: [TypeAnnotation] = []
            repeat {
                arguments.append(try parseType())
                skipSpaces()
            } while consume(",")
            guard consume(">") else { throw expected("'>'") }
            guard arguments.count == generic.genericParameters.count else {
                throw SyntaxError("\(name) takes \(generic.genericParameters.count) generic argument\(generic.genericParameters.count == 1 ? "" : "s")")
            }
            return TypeAnnotation.spelled(name, arguments) ?? .generic(name, arguments)
        }
        if let spelled = TypeAnnotation.spelled(name) { return spelled }
        guard kind(of: name) == .type else { throw SyntaxError("unknown type '\(name)'") }
        return .named(name)
    }

    /// An identifier that isn't a keyword; `_` is allowed.
    @_spi(Shell) public mutating func parseName(after context: String) throws(SyntaxError) -> String {
        guard let name = identifier() else { throw expected("a name after \(context)") }
        guard !Parser.keywords.contains(name) else { throw SyntaxError("'\(name)' is a keyword") }
        pos += name.count
        return name
    }
}
