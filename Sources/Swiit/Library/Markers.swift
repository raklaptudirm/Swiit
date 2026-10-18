import Foundation

// MARK: Markers

/// `@Flag("n") times: Int = 1`: a short flag on the command line. It only
/// marks the parameter for the bridge generator; the value passes through.
/// `@Flag all: Bool = false` alone makes the parameter's first letter the
/// flag (`-a`), which is the form a symbol graph can read: it keeps the
/// attribute's name but not its arguments.
@propertyWrapper
public struct Flag<T> {
    public var wrappedValue: T
    public init(wrappedValue: T, _ short: Character) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

/// `@Rest _ paths: [FilePath] = []`: takes any number of arguments, as
/// `FilePath...` does in Swift, which can't pass the array on to another
/// variadic: so it's declared as the array, and marked.
@propertyWrapper
public struct Rest<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

/// `@Input _ lines: [String]`: receives what's piped in, per item, or the
/// whole stream for a list. Only a marker for the bridge generator.
@propertyWrapper
public struct Input<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

