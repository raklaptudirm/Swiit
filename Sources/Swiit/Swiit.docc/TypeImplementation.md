# ``Swiit/TypeImplementation``

What a host says of a type it offers scripts: its symbol, and the members with the Swift that runs when a
script uses them.

## Overview

A ``TypeImplementation`` is a type ``Symbol`` (see ``Symbol/Nominal``) plus a list of ``SymbolImplementation`` members. A generator writes
one for each type a Swift module defines for scripts; a host writes one by hand for a type the generator did not
describe. For a Swift value type, ``BridgedType`` writes it from key paths and method references, so each member's
types are the compiler's. Hand it to ``Interpreter/register(_:)-(TypeImplementation)``, which gives back the
``TypeRef`` that names the type.

## Topics

### Making one

- ``init(name:members:)``
- ``BridgedType``

### What scripts see

- ``symbol``
- ``name``
- ``genericParameters``
- ``conformances``

### What runs

- ``members``
- ``SymbolImplementation``

### Registering it

- ``Interpreter/register(_:)-(TypeImplementation)``
