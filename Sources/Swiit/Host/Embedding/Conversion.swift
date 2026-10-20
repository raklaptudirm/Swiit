import Foundation

extension Interpreter {
    /// `value` as a `type`, converting as a call's argument is: nil if it is not one. A list's elements are converted too.
    public func convert(_ value: Value, to type: ValueType) -> Value? {
        inCurrentTask { conform(value, to: TypeAnnotation(type)) }
    }

    /// Text as a value of `type`, as a word on a command line is: an enum's case by its name (`directory` or `.directory`)
    /// or raw value, a Swift type by its own initializer from text (`5` for an `Int`, a path for a `FilePath`), a key path by
    /// the field names (`size`, `owner.name`), and anything else by being text, as `String`, `Any` and a type parameter are.
    /// Nil if the text is not one.
    public func value(fromWord text: String, as type: ValueType) -> Value? {
        inCurrentTask { word(text, as: TypeAnnotation(type)) }
    }

    /// Whether a word can be a value of `type` at all: an enum, a Swift type text can be, a key path, or anything text satisfies.
    /// (`value(fromWord:as:)` says whether one word is.)
    public func acceptsWords(as type: ValueType) -> Bool {
        inCurrentTask { acceptsWords(TypeAnnotation(type)) }
    }

    private func acceptsWords(_ type: TypeAnnotation) -> Bool {
        switch type {
        case .any, .unknown, .parameter, .keyPath: return true
        case .optional(let wrapped): return acceptsWords(wrapped)
        case .named(let name) where enumType(named: name) != nil: return true
        case .named(let name) where lookup(name) == nil && Bridge.types[name] == nil: return true
        default:
            guard let (bridged, _) = Bridge.type(of: type) else { return false }
            return bridged.parse != nil || bridged.literal != nil
        }
    }

    /// A case without associated values of an enum a script or the host declared: `value(ofCase: "directory", in: "FileType")`.
    /// Nil if there is no such enum or case.
    public func value(ofCase name: String, in enumName: String) -> Value? {
        inCurrentTask {
            guard let type = enumType(named: enumName), let definition = type.case(named: name), definition.labels.isEmpty else { return nil }
            return .enumValue(EnumValue(type: type, name: name))
        }
    }

    /// The type a value has in a script.
    public func valueType(of value: Value) -> ValueType {
        inCurrentTask { ValueType(TypeChecker(interpreter: self).type(of: value)) }
    }

    private func word(_ text: String, as type: TypeAnnotation) -> Value? {
        if case .named(let name) = type, let enumType = enumType(named: name) { return enumCase(fromText: text, enumType) }
        // A Swift type text can be, by its own declarations: `--n 3` for an Int, `--separator " "` for a Character.
        if let (bridged, _) = Bridge.type(of: type), let made = Bridge.value(of: bridged.name, from: text) { return made }
        switch type {
        case .any, .unknown, .parameter: return .string(text)
        case .keyPath: return .function(KeyPathValue(path: text.split(separator: ".").map(String.init)))
        case .optional(let wrapped): return word(text, as: wrapped)
        // A name nothing is declared under is a type parameter, which text satisfies.
        case .named(let name) where lookup(name) == nil && Bridge.types[name] == nil: return .string(text)
        default: return nil
        }
    }
}
