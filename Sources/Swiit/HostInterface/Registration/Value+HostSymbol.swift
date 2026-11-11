import Foundation

// A function a host described, as a value.

extension Value {
    /// A described function as a value, for a host object's method to give: `.function(...)` of its
    /// own making.
    public init(_ function: HostSymbol) {
        precondition(
            function.function != nil,
            "\(function.name) is a member of a type, not a function"
        )
        self = .function(NativeFunction(function))
    }
}
