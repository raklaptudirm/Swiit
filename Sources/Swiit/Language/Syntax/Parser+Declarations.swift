import Foundation
import SwishKit

extension Parser {
    /// `enum Name[: RawType] { case a, b = raw; case c(label: Type, Type) }`
    @_spi(Shell) public mutating func parseEnum() throws(SyntaxError) -> EnumDecl {
        keyword("enum")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'enum'")
        mark(.type, from: nameStart)
        skipSpaces()
        var rawType: TypeAnnotation?
        var conformances: [String] = []
        if consume(":") {
            // A raw type first, if any, then protocols.
            skipSpaces()
            if let word = identifier(), !Parser.protocols.contains(word) {
                rawType = try parseType()
                guard [.int, .string, .double].contains(rawType!) else {
                    throw SyntaxError("an enum's raw values can be Int, String or Double, not \(rawType!)")
                }
                skipSpaces()
                if consume(",") { conformances = try parseConformances() }
            } else {
                conformances = try parseConformances()
            }
            skipSpaces()
        }
        guard consume("{") else { throw expected("'{'") }

        var cases: [EnumCaseDecl] = []
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            guard identifier() == "case" else { throw expected("'case'") }
            keyword("case")
            repeat {
                skipSpaces()
                let caseStart = pos
                let caseName = try parseName(after: "'case'")
                mark(.constant, from: caseStart)
                var associated: [AssociatedValue] = []
                if consume("(") {
                    bracketDepth += 1
                    defer { bracketDepth -= 1 }
                    skipSpaces()
                    while !consume(")") {
                        // `code: Int` has a label; a bare `Int` doesn't.
                        var label: String?
                        if let word = identifier() {
                            var after = pos + word.count
                            while after < chars.count && chars[after] == " " { after += 1 }
                            if after < chars.count && chars[after] == ":" {
                                label = word
                                pos = after + 1
                                skipSpaces()
                            }
                        }
                        associated.append(AssociatedValue(label: label, type: try parseType()))
                        skipSpaces()
                        if consume(",") { skipSpaces() } else if peek() != ")" { throw expected("',' or ')'") }
                    }
                }
                skipSpaces()
                var rawValue: Expr?
                if peek() == "=" && peek(1) != "=" {
                    pos += 1
                    skipSpaces()
                    rawValue = try parseUnary()
                }
                cases.append(EnumCaseDecl(name: caseName, rawValue: rawValue, associated: associated))
                skipSpaces()
            } while consume(",")
        }
        var seen: Set<String> = []
        for enumCase in cases where !seen.insert(enumCase.name).inserted {
            throw SyntaxError("duplicate case '\(enumCase.name)' in enum \(name)")
        }
        scopes[scopes.count - 1][name] = .type
        return EnumDecl(name: name, rawType: rawType, cases: cases, conformances: conformances)
    }

    /// `struct Name { … }`: properties, methods and initializers. In their
    /// bodies, members are in scope and go through `self`, as in Swift.
    @_spi(Shell) public mutating func parseStruct() throws(SyntaxError) -> StructDecl {
        keyword("struct")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'struct'")
        mark(.type, from: nameStart)
        skipSpaces()
        var conformances: [String] = []
        if consume(":") {
            conformances = try parseConformances()
            skipSpaces()
        }
        guard consume("{") else { throw expected("'{'") }
        // Bound first, so members can use the type.
        scopes[scopes.count - 1][name] = .type
        var members: [String: NameKind] = ["self": .variable]
        for member in memberNames() { members[member] = .member }
        // What static members' bodies see: the static names, by the type's name.
        var staticMembers: [String: NameKind] = [:]
        for member in memberNames(static: true) { staticMembers[member] = .staticMember(of: name) }
        scopes.append(members)
        defer { scopes.removeLast() }

        var decl = StructDecl(name: name, properties: [], methods: [], initializers: [], conformances: conformances)
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            switch identifier() {
            case "var", "let":
                decl.properties.append(try parseProperty())
            case "func":
                decl.methods.append(try parseFunction(method: true))
            case "mutating":
                keyword("mutating")
                skipSpaces()
                guard identifier() == "func" else { throw expected("'func' after 'mutating'") }
                var method = try parseFunction(method: true)
                method.isMutating = true
                decl.methods.append(method)
            case "static":
                keyword("static")
                skipSpaces()
                scopes.append(staticMembers)
                defer { scopes.removeLast() }
                switch identifier() {
                case "var", "let": decl.staticProperties.append(try parseProperty())
                case "func": decl.staticMethods.append(try parseFunction(method: true))
                default: throw expected("'var', 'let' or 'func' after 'static'")
                }
            case "init":
                decl.initializers.append(try parseInitializer())
            default:
                throw SyntaxError("a struct holds properties (var, let), methods (func), initializers (init) and static members")
            }
        }
        var seen: Set<String> = []
        for member in decl.properties.map(\.name) + Set(decl.methods.map(\.name)) where !seen.insert(member).inserted {
            throw SyntaxError("\(name) declares '\(member)' twice")
        }
        var seenStatic: Set<String> = []
        for member in decl.staticProperties.map(\.name) + Set(decl.staticMethods.map(\.name)) where !seenStatic.insert(member).inserted {
            throw SyntaxError("\(name) declares static '\(member)' twice")
        }
        return decl
    }

    /// `var x: Int`, `let y = 2`, or a computed `var z: Int { … }`.
    @_spi(Shell) public mutating func parseProperty() throws(SyntaxError) -> PropertyDecl {
        let word = identifier()!
        keyword(word)
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'\(word)'")
        mark(.variable, from: nameStart)
        skipSpaces()
        var property = PropertyDecl(name: name, mutable: word == "var")
        if consume(":") {
            property.type = try parseType()
            skipSpaces()
        }
        if consume("{") {
            guard property.mutable else { throw SyntaxError("computed property '\(name)' must be declared with 'var'") }
            guard property.type != nil else { throw SyntaxError("computed property '\(name)' needs a type") }
            property.getter = try parseFunctionBody(parameters: [], anonymous: false).0
            property.getterNames = lastBodyNames
        } else if peek() == "=" && peek(1) != "=" {
            pos += 1
            property.defaultValue = try parseExpression()
        } else if property.type == nil {
            throw SyntaxError("property '\(name)' needs a type or a value")
        }
        return property
    }

    /// `init(x: Int) { self.x = x }`.
    @_spi(Shell) public mutating func parseInitializer() throws(SyntaxError) -> FunctionDecl {
        let documentation = documentation(before: pos)
        keyword("init")
        skipSpaces()
        guard peek() == "(" else { throw expected("'(' after 'init'") }
        let parameters = try parseParameters(named: true)
        skipSpaces()
        let throwing = parseThrows()
        guard consume("{") else { throw expected("'{'") }
        let (body, _) = try parseFunctionBody(parameters: parameters, anonymous: false)
        return FunctionDecl(name: "init", parameters: parameters, returnType: nil, body: body,
                            documentation: documentation, isMutating: true, isThrowing: throwing, names: lastBodyNames)
    }

    /// The names a struct's body declares, found before parsing it so a
    /// member can use one declared further down.
    @_spi(Shell) public func memberNames(static wantStatic: Bool = false) -> [String] {
        declaredNames(["var", "let", "func"], statementsOnly: false, statics: wantStatic).map(\.name)
    }

    /// The names declared ahead, at this level of nesting, up to the end of
    /// the block: each with the keyword that declares it. With
    /// `statementsOnly`, only where a statement starts, so `echo func x`
    /// declares nothing.
    @_spi(Shell) public func declaredNames(_ keywords: Set<String>, statementsOnly: Bool, statics wantStatic: Bool = false) -> [(keyword: String, name: String)] {
        var names: [(keyword: String, name: String)] = []
        var depth = 0
        var index = pos
        var nameFollows: String?
        // A `static` member isn't in scope by its bare name in a method: it's
        // reached through the type.
        var afterStatic = false
        var skipName = false
        while index < chars.count {
            let c = chars[index]
            if c == "\"" || c == "'" {
                index += 1
                while index < chars.count && chars[index] != c {
                    if chars[index] == "\\" && c == "\"" { index += 1 }
                    index += 1
                }
            } else if c == "/" && index + 1 < chars.count && chars[index + 1] == "/" {
                while index < chars.count && chars[index] != "\n" { index += 1 }
            } else if "{([".contains(c) {
                depth += 1
            } else if "})]".contains(c) {
                if depth == 0 { break }
                depth -= 1
            } else if depth == 0, Parser.isIdentifierStart(c), index == 0 || !Parser.isIdentifierPart(chars[index - 1]) {
                var end = index
                while end < chars.count && Parser.isIdentifierPart(chars[end]) { end += 1 }
                let word = String(chars[index..<end])
                if let keyword = nameFollows {
                    if !skipName { names.append((keyword, word)) }
                    nameFollows = nil
                    skipName = false
                } else if word == "static" && !statementsOnly {
                    afterStatic = true
                } else if keywords.contains(word) && (!statementsOnly || startsStatement(index)) {
                    nameFollows = word
                    skipName = afterStatic != wantStatic
                    afterStatic = false
                }
                index = end
                continue
            }
            index += 1
        }
        return names
    }

    /// `Equatable, Hashable` after a type's `:`.
    @_spi(Shell) public mutating func parseConformances() throws(SyntaxError) -> [String] {
        var names: [String] = []
        repeat {
            skipSpaces()
            let start = pos
            guard let name = identifier() else { throw expected("a protocol") }
            guard Parser.protocols.contains(name) else {
                throw SyntaxError("unknown protocol '\(name)'; Swish has \(Parser.protocols.sorted().joined(separator: ", "))")
            }
            pos += name.count
            mark(.type, from: start)
            names.append(name)
            skipSpaces()
        } while consume(",")
        return names
    }

    @_spi(Shell) public mutating func parseDeclaration() throws(SyntaxError) -> Statement {
        let keyword = identifier()!
        self.keyword(keyword)
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'\(keyword)'")
        mark(.variable, from: nameStart)
        skipSpaces()
        var type: TypeAnnotation?
        if consume(":") {
            type = try parseType()
            skipSpaces()
        }
        guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after '\(name)'") }
        pos += 1
        var value = try parseExpression()
        if let type { value = .annotated(value, type) }
        scopes[scopes.count - 1][name] = .variable
        return .declare(name: name, mutable: keyword == "var", value: value)
    }
}
