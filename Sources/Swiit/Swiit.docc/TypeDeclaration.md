# ``Swiit/TypeDeclaration``

What is said of a type: its symbol and what its Swift type says of itself. A type a script declares, a type a host
offers and a type the core bridges are described the same way.

## Overview

A declaration is a ``Symbol`` of kind `type` (see ``Symbol/Kind``), with what only a type has: the generic parameters it is
generic over and the protocols it conforms to, each with what its generic parameters must be for it. Ask the interpreter for
one with ``Interpreter/declaration(ofType:)``. What the type has (its methods, properties, initializers, cases and
associated types) is read with ``TypeExpression/members(named:in:)``, and how a host provides them is a
``TypeImplementation``.

## Topics

### Reading a declaration

- ``symbol``
- ``name``
- ``genericParameters``
- ``conformances``

### The kind of type

- ``Kind``

### Making one

- ``init(symbol:)``
- ``init(name:)``
