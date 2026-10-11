// SwiitKit was SwishKit. Code written against it builds unchanged: these
// are its types' and macros' old names, and the SwishKit package
// (Packages/SwishKit) is a module of that name that brings in SwiitKit.
//
// What can't keep its old name is a protocol requirement: a type that
// conforms by hand implements `swiitValue`, `swiitDescription` and the rest.
// (A function exported with `@SwishExport` is unaffected: the macro writes
// what it needs.)

@available(*, deprecated, renamed: "SwiitObject")
public typealias SwishObject = SwiitObject
@available(*, deprecated, renamed: "SwiitError")
public typealias SwishError = SwiitError
@available(*, deprecated, renamed: "SwiitType")
public typealias SwishType = SwiitType
@available(*, deprecated, renamed: "SwiitConvertible")
public typealias SwishConvertible = SwiitConvertible
@available(*, deprecated, renamed: "SwiitDisplayed")
public typealias SwishDisplayed = SwiitDisplayed
@available(*, deprecated, renamed: "SwiitEnum")
public typealias SwishEnum = SwiitEnum
@available(*, deprecated, renamed: "SwiitValue")
public typealias SwishValue = SwiitValue
@available(*, deprecated, renamed: "HostContext")
public typealias ShellContext = HostContext

/// `@SwiitExport`'s old name.
@attached(peer, names: prefixed(__swiit_export_))
public macro SwishExport() = #externalMacro(module: "SwiitKitMacros", type: "SwiitExportMacro")

/// `@SwiitObject`'s old name.
@attached(extension, conformances: SwiitObject, Sendable, names: named(typeName), named(memberNames), named(member), named(description))
public macro SwishObject() = #externalMacro(module: "SwiitKitMacros", type: "SwiitObjectMacro")
