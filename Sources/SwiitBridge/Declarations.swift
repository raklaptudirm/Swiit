import Foundation

// MARK: Declarations

struct Parameter {
    let label: String?
    let name: String
    let type: SType
    let defaultText: String?
    /// `@Flag("a")`: a short flag on the command line.
    var shortFlag: Character?
    /// `@Input`: what's piped in.
    var isInput = false
    /// `@Rest`: an array that takes all the remaining arguments.
    var isRest = false
}

/// A member's declaration, as far as its text says; its constraints come
/// from the symbol graph.
struct Declaration {
    enum Kind { case method, property, initializer }
    let kind: Kind
    let name: String
    let isStatic: Bool
    let isMutating: Bool
    let isFailable: Bool
    /// Its own generic parameters, with the protocols written beside them.
    let generics: [String: [String]]
    let parameters: [Parameter]
    let returns: SType?
    let throwing: Bool
    let rethrowing: Bool
    /// `throws(E)`: E, a generic parameter only for the error.
    let typedError: String?
    /// Its `where` clause, which the graph doesn't always give separately.
    var constraints: [Constraint] = []
    /// `+`, `<`: written between its operands (or before the one).
    var isOperator = false
}

/// `A: P & Q, B == C`, as the graph writes constraints.
func whereConstraints(_ text: String) -> [Constraint] {
    var parts: [String] = []
    var depth = 0
    var current = ""
    for c in text {
        if "(<[".contains(c) { depth += 1 }
        if ")>]".contains(c) { depth -= 1 }
        if c == "," && depth == 0 { parts.append(current); current = ""; continue }
        current.append(c)
    }
    parts.append(current)
    var constraints: [Constraint] = []
    for part in parts {
        if let range = part.range(of: "==") {
            constraints.append(Constraint(kind: "sameType", lhs: part[..<range.lowerBound].trimmingCharacters(in: .whitespaces),
                                          rhs: part[range.upperBound...].trimmingCharacters(in: .whitespaces)))
        } else if let colon = part.firstIndex(of: ":") {
            let lhs = part[..<colon].trimmingCharacters(in: .whitespaces)
            for proto in part[part.index(after: colon)...].split(separator: "&") {
                let name = proto.trimmingCharacters(in: .whitespaces)
                if !name.hasPrefix("~") { constraints.append(Constraint(kind: "conformance", lhs: lhs, rhs: name)) }
            }
        }
    }
    return constraints
}

func parseDeclaration(_ text: String) throws -> Declaration {
    var reader = Reader(text)
    var isStatic = false
    var isMutating = false
    // Attributes and modifiers before the declaration itself.
    while true {
        reader.skipSpaces()
        if reader.peek() == "@" {
            reader.pos += 1
            _ = reader.identifier()
            if reader.peek() == "(" {
                var depth = 0
                repeat {
                    if reader.peek() == "(" { depth += 1 }
                    if reader.peek() == ")" { depth -= 1 }
                    reader.pos += 1
                } while depth > 0 && !reader.atEnd
            }
            continue
        }
        let save = reader.pos
        guard let word = reader.identifier() else { throw Unsupported(reason: "declaration") }
        switch word {
        case "static", "class": isStatic = true
        case "mutating": isMutating = true
        case "nonmutating", "public", "final", "override", "convenience", "required", "optional", "dynamic", "lazy", "nonisolated",
             "prefix", "postfix": break
        default: reader.pos = save
        }
        if reader.pos == save { break }
    }
    var generics: [String: [String]] = [:]
    var typedError: String?
    func genericParameters(_ reader: inout Reader) throws {
        guard reader.consume("<") else { return }
        repeat {
            guard let name = reader.identifier() else { throw Unsupported(reason: "generic parameter") }
            if reader.consume("...") { throw Unsupported(reason: "variadic generics") }
            generics[name, default: []] += reader.consume(":") ? try reader.protocols() : []
        } while reader.consume(",")
        guard reader.consume(">") else { throw Unsupported(reason: "generics") }
    }
    func parameterList(_ reader: inout Reader) throws -> [Parameter] {
        guard reader.consume("(") else { throw Unsupported(reason: "parameters") }
        var parameters: [Parameter] = []
        if reader.consume(")") { return parameters }
        repeat {
            // SwishKit's `@Flag("a")` and `@Input`, which mark a parameter.
            var shortFlag: Character?
            var firstLetter = false
            var isInput = false
            var isRest = false
            reader.skipSpaces()
            while reader.consume("@") {
                switch reader.identifier() {
                case "Flag":
                    // `@Flag("a")`, or `@Flag` alone: the parameter's first letter.
                    if reader.consume("(") {
                        guard reader.consume("\""), let letter = reader.peek() else { throw Unsupported(reason: "@Flag") }
                        reader.pos += 1
                        guard reader.consume("\""), reader.consume(")") else { throw Unsupported(reason: "@Flag") }
                        shortFlag = letter
                    } else {
                        firstLetter = true
                    }
                case "Input": isInput = true
                case "Rest": isRest = true
                default: throw Unsupported(reason: "attribute")
                }
                reader.skipSpaces()
            }
            guard let first = reader.identifier() else { throw Unsupported(reason: "parameter") }
            var name = first
            var label: String? = first
            if let second = reader.identifier() { name = second }
            if first == "_" { label = nil }
            guard reader.consume(":") else { throw Unsupported(reason: "parameter type") }
            let type = try reader.type()
            if reader.consume("...") { throw Unsupported(reason: "variadic") }
            var defaultText: String?
            if reader.consume("=") {
                // Up to the next comma or `)` at this depth.
                var depth = 0
                var text = ""
                while let c = reader.peek(), !(depth == 0 && (c == "," || c == ")")) {
                    if "([<".contains(c) { depth += 1 }
                    if ")]>".contains(c) { depth -= 1 }
                    text.append(c)
                    reader.pos += 1
                }
                defaultText = text.trimmingCharacters(in: .whitespaces)
            }
            if firstLetter { shortFlag = (label ?? name).first }
            parameters.append(Parameter(label: label, name: name, type: type, defaultText: defaultText, shortFlag: shortFlag, isInput: isInput, isRest: isRest))
        } while reader.consume(",")
        guard reader.consume(")") else { throw Unsupported(reason: "parameters end") }
        return parameters
    }
    func effects(_ reader: inout Reader) throws -> (throwing: Bool, rethrowing: Bool) {
        if reader.consume("async") { throw Unsupported(reason: "async") }
        if reader.consume("rethrows") { return (false, true) }
        if reader.consume("throws") {
            // `throws(E)`, E from a closure it's given: it rethrows.
            if reader.consume("(") {
                guard let error = reader.identifier(), reader.consume(")") else { throw Unsupported(reason: "typed throws") }
                typedError = error
                return (false, true)
            }
            return (true, false)
        }
        return (false, false)
    }

    if reader.consume("func") {
        // An operator's operands have no labels, whatever they're called.
        let start = reader.pos
        let isOperator = reader.identifier() == nil
        reader.pos = start
        guard let name = reader.identifier() ?? reader.operatorName() else { throw Unsupported(reason: "operator") }
        if !isOperator { try genericParameters(&reader) }
        var parameters = try parameterList(&reader)
        if isOperator { parameters = parameters.map { Parameter(label: nil, name: $0.name, type: $0.type, defaultText: $0.defaultText) } }
        let (throwing, rethrowing) = try effects(&reader)
        let returns = reader.consume("->") ? try reader.type() : nil
        var declaration = Declaration(kind: .method, name: name, isStatic: isStatic, isMutating: isMutating, isFailable: false,
                                      generics: generics, parameters: parameters, returns: returns,
                                      throwing: throwing, rethrowing: rethrowing, typedError: typedError)
        declaration.isOperator = isOperator
        if reader.consume("where") { declaration.constraints = whereConstraints(String(reader.chars[reader.pos...])) }
        return declaration
    }
    if reader.consume("var") || reader.consume("let") {
        guard let name = reader.identifier(), reader.consume(":") else { throw Unsupported(reason: "property") }
        let type = try reader.type()
        return Declaration(kind: .property, name: name, isStatic: isStatic, isMutating: false, isFailable: false,
                           generics: [:], parameters: [], returns: type, throwing: false, rethrowing: false, typedError: nil)
    }
    if reader.consume("init") {
        let failable = reader.consume("?")
        if reader.consume("!") { throw Unsupported(reason: "init!") }
        try genericParameters(&reader)
        let parameters = try parameterList(&reader)
        let (throwing, rethrowing) = try effects(&reader)
        var declaration = Declaration(kind: .initializer, name: "init", isStatic: true, isMutating: false, isFailable: failable,
                                      generics: generics, parameters: parameters, returns: nil,
                                      throwing: throwing, rethrowing: rethrowing, typedError: typedError)
        if reader.consume("where") { declaration.constraints = whereConstraints(String(reader.chars[reader.pos...])) }
        return declaration
    }
    throw Unsupported(reason: "kind")
}
