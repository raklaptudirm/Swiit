# ``Swiit/TypeExpression``

A type as a signature writes it.

## Overview

A ``TypeRef`` says which type a name is. A type expression says how a type is written with it. It is one of five
cases, and each holds a type of its own: a ``TypeExpression/Named`` type with the types it is generic over (`Array<Int>`),
a ``TypeExpression/FunctionType``, a ``TypeExpression/Tuple``, a ``TypeExpression/Metatype``, or a
``TypeExpression/GenericParameter`` (`Element`). The static members are shorthand for the common ones, and
``TypeExpression/members(named:in:)`` lists what a type has.

## Topics

### The forms of a type

- ``named(_:)``
- ``parameter(_:)``
- ``function(_:)``
- ``tuple(_:)``
- ``metatype(_:)``

### What each form holds

- ``Named``
- ``GenericParameter``
- ``FunctionType``
- ``Tuple``
- ``TupleElement``
- ``Metatype``

### Common types

- ``any``
- ``bool``
- ``int``
- ``double``
- ``string``
- ``void``
- ``callable``
- ``list(_:)``
- ``dictionary(_:_:)``
- ``optional(_:)``
- ``function(parameters:returns:isThrowing:isAsync:)``

### Asking about a type

- ``members(named:in:)``
- ``conforms(to:in:)``

### Making one from a Swift type

- ``init(_:)``
