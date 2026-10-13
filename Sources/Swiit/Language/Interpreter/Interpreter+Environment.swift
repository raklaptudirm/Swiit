import Foundation
import SwiitKit
import SwiitStandardLibrary

extension Interpreter {
    /// Joins a string's parts into one string. Interpolation never splits.
    func expand(_ parts: [StringPart]) throws -> String {
        try parts.map { part in
            switch part {
            case .literal(let text): text
            case .expression(let expr): try describing(try evaluate(expr))
            }
        }.joined()
    }

    /// What `print` and interpolation show, as Swift does: a String as it is,
    /// a struct by its `description` if it says it's a CustomStringConvertible
    /// (and its `debugDescription` for `debug`, in a collection or a tuple),
    /// and anything inside a collection the way `debugPrint` shows it, so a
    /// text in an array has its quotes.
    /// A type of the program's with its module in front, as Swift shows it where it is shown whole
    /// (`main.Point(x: 1)` in an array, `main.Color.red`); Swiit's own types by their names.
    func qualified(_ name: String) -> String {
        let declared = scopes.dropFirst().contains { scope in
            guard case .object(let object)? = scope.bindings[name]?.value else { return false }
            return object is StructType || object is EnumType || object is ClassType
        }
        return declared ? moduleName + "." + name : name
    }

    func describing(_ value: Value, debug: Bool = false, type: TypeAnnotation? = nil) throws -> String {
        // What the type knows: an optional is `Optional(…)` or `nil`, and so is one inside a collection.
        switch type {
        case .optional(let wrapped)?:
            if value == .nothing { return "nil" }
            return "Optional(" + (try describing(value, debug: true, type: wrapped)) + ")"
        case .list(let element)?:
            if case .list(let items) = value {
                return "[" + (try items.map { try describing($0, debug: true, type: element) }).joined(separator: ", ") + "]"
            }
        case .dictionary(let keyType, let valueType)?:
            if case .dictionary(let dictionary) = value {
                guard dictionary.count > 0 else { return "[:]" }
                return "[" + (try dictionary.sortedForDisplay.map {
                    "\(try describing($0.key, debug: true, type: keyType)): \(try describing($0.value, debug: true, type: valueType))"
                }).joined(separator: ", ") + "]"
            }
        case .tuple(let elements)?:
            if case .record(let record) = value, record.typeName == nil, record.count == elements.count {
                return "(" + (try zip(record, elements).map { field, element in
                    (Record.isPosition(field.key) ? "" : "\(field.key): ") + (try describing(field.value, debug: true, type: element.type))
                }).joined(separator: ", ") + ")"
            }
        default:
            break
        }
        switch value {
 case .enumValue(let enumValue) where debug && enumValue.values.isEmpty && enumValue.type.name != "Never":
            return qualified(enumValue.type.name) + "." + enumValue.name
        case .enumValue(let enumValue) where !enumValue.values.isEmpty:
            let labels = enumValue.definition?.labels ?? []
            let payloads = enumPayloadTypes[ObjectIdentifier(enumValue.type)]?[enumValue.name] ?? []
            return (debug ? qualified(enumValue.type.name) + "." : "") + enumValue.name + "(" + (try enumValue.values.enumerated().map { index, item in
                let label = index < labels.count ? labels[index] : nil
                return (label.map { "\($0): " } ?? "") + (try describing(item, debug: true, type: index < payloads.count ? payloads[index] : nil))
            }).joined(separator: ", ") + ")"
        case .string(let text):
            return debug ? value.debugDescription : text
        // A type is shown as its name, as `print(Int.self)` does.
        case .object(let type as StructType):
            return type.name
        case .object(let type as EnumType):
            return type.name
        case .object(let type as BridgedTypeName):
            return type.name
        case .object(let type as ClassType):
            return type.name
        case .object(let instance as ClassInstance):
            if conformanceList(of: value).contains("CustomStringConvertible"), let text = try classMember("description", of: instance) {
                return try describing(text)
            }
            return qualified(instance.type.name)
        case .list(let items):
            return "[" + (try items.map { try describing($0, debug: true) }).joined(separator: ", ") + "]"
        case .dictionary(let dictionary):
            guard dictionary.count > 0 else { return "[:]" }
            return "[" + (try dictionary.sortedForDisplay.map {
                "\(try describing($0.key, debug: true)): \(try describing($0.value, debug: true))"
            }).joined(separator: ", ") + "]"
        case .record(let record):
            if let type = structType(of: record) {
                let conformances = conformanceList(of: value)
                if debug, conformances.contains("CustomDebugStringConvertible"), let text = try extensionMember("debugDescription", of: value) ?? structMember("debugDescription", of: record, type) {
                    return try describing(text)
                }
                if conformances.contains("CustomStringConvertible"), let text = try extensionMember("description", of: value) ?? structMember("description", of: record, type) {
                    return try describing(text)
                }
            }
            let declared = structType(of: record)
            let shownName = record.typeName.map { debug ? qualified($0) : $0 } ?? ""
            return shownName + "(" + (try record.map { field in
                (Record.isPosition(field.key) ? "" : "\(field.key): ")
                    + (try describing(field.value, debug: true, type: declared?.property(field.key)?.type))
            }).joined(separator: ", ") + ")"
        default:
            return debug ? value.debugDescription : value.description
        }
    }
}
