/// A type with an ID: one a program declares (a struct, class, actor, enum or protocol), or an enum
/// the host provides.
protocol DeclaredType: AnyObject {
    var id: Symbol.ID { get }
}
