# ``Swiit/Symbol/Nominal``

What a type symbol has beyond a name: its kind, the reference that names it, the types it is generic over and
the protocols it conforms to.

## Overview

A type is a ``Symbol`` of kind `type`, and ``Symbol/Nominal`` is that kind's payload, as ``Symbol/Function`` is a function's.
A type a script declares, a type a host offers and a type the core bridges are described the same way. Ask a
``TypeRef`` for one with ``TypeRef/symbol(in:)``, or read ``Symbol/nominal`` on a symbol of ``Interpreter/types``.
What the type has (its methods, properties, initializers, cases and associated types) is read with
``TypeExpression/members(named:in:)``, and how a host provides them is an ``ImplementedType``.

## Topics

### What a type has

- ``kind``
- ``typeRef``
- ``genericParameters``
- ``conformances``

### The kinds of nominal type

- ``Kind``

### Making one

- ``init(kind:typeRef:genericParameters:conformances:)``
