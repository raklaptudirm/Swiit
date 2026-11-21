# ``Swiit/Symbol``

Something a script can name: a function, a variable, a type, a member of a type or a generic parameter.

## Overview

A symbol is one of nine cases, and each holds a struct that has everything its kind has: a function's
``Symbol/Function``, a variable's ``Symbol/Variable``, a type's ``Symbol/Nominal``, and so on. All of them hold a
``Symbol/Header`` (the name, the summary and the attributes) and conform to ``SymbolProtocol``, so the name is read the
same way from each. An API that always gives one kind names that kind (``TypeRef/symbol(in:)`` gives a
``Symbol/Nominal``); an API that may give any gives a `Symbol` to switch over.

``Interpreter/globals(named:)`` returns symbols, ``Interpreter/types`` returns the types among them, and
``TypeExpression/members(named:in:)`` lists the members of a type. A function, a method and an initializer share
their ``Symbol/Signature`` and ``CallableSymbol``, so ``Swift/Sequence/overload(arguments:in:)`` works on a list of any
of them.

## Topics

### Reading a symbol

- ``SymbolProtocol``
- ``Header``
- ``name``
- ``summary``
- ``attributes``
- ``isBuiltin``

### Types

- ``Nominal``
- ``GenericParameter``
- ``Constraint``

### Functions and their members

- ``CallableSymbol``
- ``Signature``
- ``Function``
- ``Method``
- ``Initializer``
- ``Parameter``
- ``Throwing``

### Variables and properties

- ``Variable``
- ``Property``

### Cases and associated types

- ``EnumCase``
- ``AssociatedType``

### Attributes

- ``Attribute``
