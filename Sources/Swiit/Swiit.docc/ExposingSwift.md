# Registering Swift functions, types and objects

A script can call a Swift closure, hold a Swift value type, use a live object, and see types declared in Swift source. Each has its own entry
point, listed here in that order.

## Register a closure as a function

``Interpreter/register(_:labels:throwing:_:)-f2lx`` takes a name and a closure, such as `register("double") { (n: Int) in n * 2 }`. When the
parameter types are only known at run time, build a ``HostSymbol`` with ``HostSymbol/function(name:summary:parameters:returns:isThrowing:generics:attributes:body:)-(_,_,_,ScriptType,_,_,_,_)`` (a name, a summary, a signature and a body), and pass it to
``Interpreter/register(_:)->()``.

## Register a Swift value type

``HostTypeBuilder`` makes a Swift value type, such as `URL` or a file size, usable in scripts without declaring it in Swift source. A script can
store it, compare it with `==` and `<`, hash it, and call the members you register. The checker validates those calls before the script runs. A
piece of text becomes a value of the type through its `parse` function.

A `CaseIterable` Swift enum that conforms to ``ScriptConvertible`` is an enum in scripts: `.dark` is one of its cases, `case .dark:` matches
it, and `rawValue` is its own. Registering a type declares every such enum its members take or give, as registering a function declares the
ones it takes or gives, so a struct with a `shade: Shade` property needs nothing more for scripts to name `Shade`.

## Hand scripts a live object

A class that conforms to ``ScriptConvertible`` reaches scripts by reference: it is equal only to itself unless it is `Hashable`. Its members are
the ones its ``HostTypeBuilder`` registers, and a type, class or struct, can answer for names looked up only at run time by saying
``ScriptConvertible/memberNames`` and ``ScriptConvertible/member(_:)``: a parsed object's keys, a job's fields.

## Declare types and functions in Swift

``Interpreter/declare(_:bodies:)`` reads Swift source made of types, protocols, functions and `Sequence` methods. A function without a
body takes the Swift closure registered under its name in `bodies`; one with a body runs as Swiit. A class or struct declared this way can be
marked `@dynamicMemberLookup`, so that `env.HOME` calls its `subscript(dynamicMember:)`.

## How values cross over

A script sees every argument and result as a ``Value``, and a ``ScriptType`` names its type, such as `.int` or `.list(.string)`.
``ScriptConvertible`` is the protocol a Swift type adopts to convert to and from `Value`.
