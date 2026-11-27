import Foundation

// Calls and members: a function by name, a method of a local, of `self` or of a global, `super`'s,
// and the members of Swift's types.

/// A variable passed with `&`, which gets what the callee leaves in its `inout` parameter.
private struct InoutPlace {
    let index: Int
    let slot: Register
    let boxed: Bool
}

extension CodeCompiler {
    /// A call the VM makes itself: of a global name, a member of a global, or a local. False for any
    /// other (a call on a value, an `inout` argument that is not a local, a `.case` argument), which the
    /// tree evaluator makes.
    mutating func call(
        _ callee: Expr,
        _ arguments: [Argument],
        into destination: Register
    ) throws -> Bool {
        var named = callee
        var overload: Int?
        if case .chosen(let inner, let index) = callee {
            named = inner
            overload = index
        }
        enum Target {
            case name(String)
            case member
            case value(Register)
        }
        for argument in arguments {
            switch argument.value {
            case .caseLiteral: return false
            case .inoutArgument(let place):
                switch place {
                case .local: break
                case .variable(let name) where lookup(name) != nil: break
                default: return false
                }
            default: break
            }
        }
        let target: Target
        switch named {
        case .variable(let called) where lookup(called) == nil: target = .name(called)
        case .member(let base, _) where isConstant(base): target = .member
        case .local, .variable:
            // A closure in a variable, or a parameter of function type.
            let held = try allocate()
            try expression(named, into: held)
            target = .value(held)
        default: return false
        }
        // The places `&x` names get what the callee leaves in its `inout` parameters.
        var places: [InoutPlace] = []
        var values: [Expr] = []
        for argument in arguments {
            switch argument.value {
            case .caseLiteral: return false
            case .inoutArgument(let place):
                var local: (slot: Register, boxed: Bool)?
                if case .local(let named) = place {
                    local = (Register(named.slot), capturedSlots.contains(named.slot))
                } else if case .variable(let name) = place, let found = lookup(name) {
                    local = (found.slot, found.boxed)
                }
                guard let local else { return false }
                places.append(InoutPlace(index: places.count, slot: local.slot, boxed: local.boxed))
                values.append(place)
            default: values.append(argument.value)
            }
        }
        let first = Register(nextTemporary)
        for value in values {
            let register = try allocate()
            try expression(value, into: register)
        }
        var name: String?
        if case .name(let called) = target { name = called }
        code.callSites.append(
            CallSite(
                name: name,
                callee: callee,
                labels: arguments.map(\.label),
                overload: overload
            )
        )
        let site = UInt32(code.callSites.count - 1)
        if case .value(let held) = target {
            emit(.callValue(dst: destination, callee: held, site: site, arguments: first))
        } else {
            emit(.call(dst: destination, site: site, arguments: first))
        }
        guard !places.isEmpty else { return true }
        for place in places {
            if place.boxed {
                let outcome = try allocate()
                emit(.calls(.takeInout(dst: outcome, index: UInt16(place.index))))
                emit(.storeCell(box: place.slot, src: outcome))
            } else {
                emit(.calls(.takeInout(dst: place.slot, index: UInt16(place.index))))
            }
        }
        emit(.calls(.finishInout))
        return true
    }

    /// `p.name(arguments)` of a local `p`: run by `callMethod` where `p` holds a struct with a plain method
    /// of that name, and by the tree evaluator, which follows it, where not. False if the receiver is not
    /// a local or an argument is not plain.
    mutating func method(
        _ base: Expr,
        _ name: String,
        _ arguments: [Argument],
        _ expression: Expr,
        into destination: Register
    ) throws -> Bool {
        var held: Local?
        switch base {
        case .local(let local): held = lookup(local.name)
        case .variable(let name): held = lookup(name)
        default: break
        }
        // `self.name(…)`, which a bare `name(…)` in a method is: on the value in the cell of `self`.
        let onSelf = held == nil && namesSelfRegister(selfName(of: base))
        // A global: its value is loaded, and a struct a method changes goes back in its cell.
        var globalName: String?
        if held == nil, !onSelf, case .variable(let name) = base, name != "self", name != "super" {
            globalName = name
        }
        guard
            onSelf || globalName != nil
                || (held.map { !$0.boxed && !weakSlots.contains(Int($0.slot)) } ?? false),
            arguments.allSatisfy({ isPure($0.value) })
        else { return false }
        let mark = nextTemporary
        var receiver = held?.slot ?? 0
        if onSelf, let cell = code.selfRegister {
            if !code.selfStorage.holdsCell {
                receiver = cell
            } else {
                receiver = try allocate()
                emit(.loadCell(dst: receiver, box: cell))
            }
        }
        var global: GlobalSite?
        if let globalName {
            global = GlobalSite(name: globalName)
            code.globals.append(global!)
            receiver = try allocate()
            emit(.loadGlobal(dst: receiver, site: UInt32(code.globals.count - 1)))
        }
        let first = Register(nextTemporary)
        for argument in arguments {
            try self.expression(argument.value, into: try allocate())
        }
        code.methods.append(
            MethodSite(
                name: name,
                labels: arguments.map(\.label),
                mayMutate: onSelf ? changesSelf : global != nil ? true : held?.mutable ?? false,
                receiverIsSelf: onSelf,
                global: global
            )
        )
        let fast = emit(
            .callMethod(
                dst: destination,
                site: UInt32(code.methods.count - 1),
                receiver: receiver,
                arguments: first,
                offset: 0
            )
        )
        nextTemporary = mark
        treeExpression(expression, into: destination)
        patch(fast, to: here)
        return true
    }

    /// `super.name(arguments)` in a method: run by `callMethod` on `self` when the class above has one
    /// plain method of that name, and by the tree evaluator, which follows it, where not.
    mutating func superMethod(
        _ name: String,
        _ arguments: [Argument],
        _ expression: Expr,
        into destination: Register
    ) throws -> Bool {
        guard let selfRegister = code.selfRegister, code.selfStorage.holdsCell, name != "init",
            arguments.allSatisfy({ isPure($0.value) })
        else { return false }
        let mark = nextTemporary
        let held = try allocate()
        emit(.loadCell(dst: held, box: selfRegister))
        let first = Register(nextTemporary)
        for argument in arguments {
            try self.expression(argument.value, into: try allocate())
        }
        code.methods.append(
            MethodSite(
                name: name,
                labels: arguments.map(\.label),
                mayMutate: false,
                isSuper: true
            )
        )
        let fast = emit(
            .callMethod(
                dst: destination,
                site: UInt32(code.methods.count - 1),
                receiver: held,
                arguments: first,
                offset: 0
            )
        )
        nextTemporary = mark
        treeExpression(expression, into: destination)
        patch(fast, to: here)
        return true
    }

    /// A member of an `Array` or a `String` held in a local, made by `fastMember` where the kinds fit
    /// and by the tree evaluator, which follows it, where they do not. False if it is not one of those.
    mutating func fastMember(_ expression: Expr, into destination: Register) throws -> Bool {
        guard case .bridged(let type, let member, let receiver?, let arguments) = expression,
            let found = bridged[type]?.lowered, member < found.count
        else { return false }
        let named = found[member]
        let kind: FastMember
        switch (type, named.name, named.kind, arguments.count) {
        case ("Array", "append", .method, 1) where named.isMutating: kind = .append
        case ("Array", "count", .property, 0): kind = .listCount
        case ("Array", "subscript", .method, 1): kind = .element
        case ("String", "count", .property, 0): kind = .stringCount
        case ("Dictionary", "subscript", .method, 1): kind = .dictionaryElement
        case ("Dictionary", "count", .property, 0): kind = .dictionaryCount
        case ("Array", "isEmpty", .property, 0), ("Dictionary", "isEmpty", .property, 0),
            ("String", "isEmpty", .property, 0):
            kind = .isEmpty
        default: return false
        }
        var held: Local?
        switch receiver {
        case .local(let local): held = lookup(local.name)
        case .variable(let name): held = lookup(name)
        default: break
        }
        // A name that is not a local is a global, whose cell the list or string is changed in.
        if held == nil, case .variable(let name) = receiver, name != "self", name != "super",
            arguments.allSatisfy({ $0.label == nil && isPure($0.value) })
        {
            let mark = nextTemporary
            let argument = try arguments.first.map { try operand($0.value) } ?? 0
            code.globals.append(GlobalSite(name: name))
            let fast = emit(
                .members(
                    .fastGlobalMember(
                        kind: kind,
                        dst: destination,
                        global: UInt32(code.globals.count - 1),
                        argument: argument,
                        offset: 0
                    )
                )
            )
            nextTemporary = mark
            treeExpression(expression, into: destination)
            patch(fast, to: here)
            return true
        }
        guard let held, !held.boxed, !weakSlots.contains(Int(held.slot)),
            kind != .append || held.mutable,
            arguments.allSatisfy({ $0.label == nil && isPure($0.value) })
        else { return false }
        let mark = nextTemporary
        let argument = try arguments.first.map { try operand($0.value) } ?? held.slot
        let fast = emit(
            .members(
                .fastMember(
                    kind: kind,
                    dst: destination,
                    receiver: held.slot,
                    argument: argument,
                    offset: 0
                )
            )
        )
        nextTemporary = mark
        treeExpression(expression, into: destination)
        patch(fast, to: here)
        return true
    }

    /// A call of a member of a Swift type that does not change its receiver: its receiver and arguments
    /// are made here, so that a call among them is the loop's, and the member is run by `callBridged`.
    /// False for what the tree evaluator must see the expressions of: a mutating member, a subscript, an
    /// argument that is a `.case` or an `inout`.
    mutating func bridgedCall(_ expression: Expr, into destination: Register) throws -> Bool {
        guard case .bridged(let type, let index, let receiver, let arguments) = expression,
            let members = bridged[type]?.lowered, index < members.count,
            case let member = members[index], !member.isMutating, member.name != "subscript"
        else { return false }
        for argument in arguments {
            switch argument.value {
            case .caseLiteral, .inoutArgument: return false
            default: break
            }
        }
        let mark = nextTemporary
        defer { nextTemporary = mark }
        var held = Register.max
        if let receiver {
            held = try allocate()
            try self.expression(receiver, into: held)
        }
        let first = Register(nextTemporary)
        for argument in arguments {
            try self.expression(argument.value, into: try allocate())
        }
        code.bridgedSites.append(
            BridgedSite(type: type, member: index, labels: arguments.map(\.label))
        )
        emit(
            .calls(
                .callBridged(
                    dst: destination,
                    site: UInt32(code.bridgedSites.count - 1),
                    receiver: held,
                    arguments: first
                )
            )
        )
        return true
    }
}
