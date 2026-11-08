# ``Swiit/Interpreter``

## Topics

### Creating an interpreter

- ``init(host:limits:)``
- ``host-swift.property``
- ``Host``
- ``Limits``

### Evaluating and checking source

- ``evaluate(_:limits:onValue:onError:completion:)-670lm``
- ``evaluate(_:limits:onValue:onError:completion:)-8o86u``
- ``check(_:)``
- ``Declarations``
- ``cancel()``

### Registering functions, types and globals

- ``register(_:)-(HostSymbol)``
- ``register(_:)-(HostTypeBuilder<T>)``
- ``register(_:)-(E.Type)``
- ``register(_:labels:throwing:_:)-f2lx``
- ``register(_:labels:throwing:_:)-29d7d``
- ``register(computed:type:_:)``
- ``declare(_:bodies:)``
- ``subscript(_:)``

### Calling script functions

- ``call(_:with:)``
- ``call(_:on:arguments:)``
- ``make(_:arguments:)``

### Looking up symbols and types

A type's members, a type ID's declaration and a candidate list's overload are asked of ``ScriptType``, ``Symbol/ID`` and a sequence of ``Symbol``.

- ``globals(named:)``
- ``types``
- ``scriptType(of:)``
- ``scriptType(ofExpression:)``
- ``highlighting(_:)``
- ``Highlight``

### Converting values and text

- ``converted(_:to:)``
- ``value(forMember:of:)``
- ``description(of:debug:)``

### Tasks, waiting and stopping

- ``startTask(state:_:)``
- ``join(_:)``
- ``cancelAndJoinTasks()``
- ``whileWaiting(_:)``
- ``whileWaiting(wake:_:)``
- ``whileWaitingForInput(_:)``
- ``taskState``
- ``cancellation``
- ``checkForStop()``
- ``file``
