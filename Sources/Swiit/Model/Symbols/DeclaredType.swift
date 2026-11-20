/// A type with a reference: one a program declares (a struct, class, actor, enum or protocol), or an enum
/// the host provides.
protocol DeclaredType: AnyObject {
    var typeRef: TypeRef { get }
}
