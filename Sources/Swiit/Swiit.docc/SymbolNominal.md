# ``Swiit/Symbol/Nominal``

A type a script can name: its kind, the reference that names it, the types it is generic over and the protocols it
conforms to.

## Overview

A type a script declares, a type a host offers and a type the core bridges are described the same way. Ask a
``TypeRef`` for one with ``TypeRef/symbol(in:)``, or list them with ``Interpreter/types``. What the type has (its
methods, properties, initializers, cases and associated types) is read with ``TypeExpression/members(named:in:)``, and
how a host provides them is an ``ImplementedType``.

## Topics

### What a type has

- ``kind``
- ``typeRef``
- ``typeExpression``
- ``genericParameters``
- ``conformances``

### The kinds of nominal type

- ``Kind``

### Making one

- ``init(name:summary:attributes:kind:typeRef:genericParameters:conformances:)``
