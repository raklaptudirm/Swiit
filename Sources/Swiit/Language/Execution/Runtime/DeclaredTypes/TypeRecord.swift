import Foundation

/// What the interpreter keeps of a type a program declares, whatever its kind: a struct, an enum, a
/// class or a protocol. It says how the type's values are stored and what is said of the type, which
/// is the same for every kind.
protocol TypeRecord: AnyObject {
    var typeRef: TypeRef { get }
    var representation: ImplementedType.Representation { get }
    /// What is said of the type, apart from its conformances, which `Interpreter.typeSymbol` adds
    /// because extensions give them too.
    var symbol: Symbol.Nominal { get }
    /// The protocols it names itself, and, for a class, those of the classes it comes from.
    var declaredConformances: [String] { get }
}

extension StructType: TypeRecord {
    var declaredConformances: [String] { conformances }
}

extension EnumType: TypeRecord {
    var typeRef: TypeRef { enumeration.typeRef }
    var declaredConformances: [String] { enumeration.conformances }
}

extension ClassType: TypeRecord {
    var declaredConformances: [String] { allConformances }
}

extension ProtocolType: TypeRecord {
    var declaredConformances: [String] { inherited }
}

extension Interpreter {
    /// The record of a type a program declared, found from the type itself.
    func record(of type: any DeclaredType) -> (any TypeRecord)? {
        switch type {
        case let type as StructType: type
        case let type as ClassType: type
        case let type as ProtocolType: type
        case let type as Value.EnumCase.Enumeration: enumTypes[ObjectIdentifier(type)]
        default: nil
        }
    }

    /// The record of the type a program declared under this name: nil for a host's type, which is
    /// described by its `ImplementedType`.
    func record(ofTypeNamed name: String) -> (any TypeRecord)? {
        switch lookup(name)?.value.storage {
        case .object(let type as StructType)?: type
        case .object(let type as ClassType)?: type
        case .object(let type as ProtocolType)?: type
        case .object(let type as Value.EnumCase.Enumeration)?: enumTypes[ObjectIdentifier(type)]
        default: nil
        }
    }
}
