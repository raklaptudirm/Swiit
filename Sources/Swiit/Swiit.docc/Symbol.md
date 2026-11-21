# ``Swiit/Symbol``

Something a script can name: a function, a variable, a type, a member of a type or a generic parameter.

## Overview

A symbol's ``Symbol/Kind`` says which one it is and holds what only that kind has: a function's ``Symbol/Function``, a
variable's ``Symbol/Variable``, a type's ``Symbol/Nominal`` and a member's ``Symbol/Member``. The name, the summary and the
attributes are on the symbol itself. ``Interpreter/globals(named:)`` and ``Interpreter/types`` return symbols, and
``TypeExpression/members(named:in:)`` lists the members of a type.

## Topics

### Reading a symbol

- ``name``
- ``summary``
- ``attributes``
- ``isBuiltin``
- ``kind``

### What the kind holds

- ``Kind``
- ``Function``
- ``Variable``
- ``Nominal``
- ``function``
- ``variable``
- ``nominal``
- ``typeRef``
- ``typeKind``
- ``typeExpression``
- ``constraints``

### Members of a type

- ``Member``
- ``Method``
- ``Property``
- ``AssociatedType``

### Parameters, generics and effects

- ``Parameter``
- ``Constraint``
- ``Throwing``

### Attributes

- ``Attribute``

### Making a symbol

- ``init(name:summary:kind:attributes:)``
- ``genericParameter(_:constraints:)``
