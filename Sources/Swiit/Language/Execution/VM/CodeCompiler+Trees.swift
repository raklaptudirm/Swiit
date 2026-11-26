import Foundation

/// What a piece of code mentions of the function's locals, found by looking through it.
private struct Mentions {
    /// By slot, from the `.local` the frame resolver made.
    var slots: [Int: String] = [:]
    /// By name, for what the resolver left (a `where`, a pattern).
    var names: Set<String> = []

    mutating func collect(_ subject: Any) {
        if subject is Value || subject is String { return }
        if let assignment = subject as? Assignment {
            names.insert(assignment.root)
            collect(assignment.value)
            collect(assignment.path)
            return
        }
        if let local = subject as? Program.Local {
            slots[local.slot] = local.name
            return
        }
        // A closure's body has a frame of its own, whose locals are not this function's: only the
        // names it uses, and what its capture list takes here, are.
        if let literal = subject as? ClosureLiteral {
            names.formUnion(literal.names.names)
            for capture in literal.captures { collect(capture.value) }
            return
        }
        let mirror = Mirror(reflecting: subject)
        if mirror.displayStyle == .enum, let child = mirror.children.first,
            child.label == "variable", let name = child.value as? String
        {
            names.insert(name)
            return
        }
        for child in mirror.children { collect(child.value) }
    }
}

extension CodeCompiler {
    /// Whether a body names `self`, in its own code or in a closure's.
    func mentionsSelf(_ body: Program) -> Bool {
        var mentions = Mentions()
        mentions.collect(body)
        return mentions.names.contains("self") || mentions.names.contains("super")
    }

    /// Whether a body assigns to `self` or a part of it, in its own code or a closure's: then the value
    /// of `self` is changed while it runs, and is kept in a cell.
    func assignsToSelf(_ body: Program) -> Bool {
        func walk(_ subject: Any) -> Bool {
            if subject is Value || subject is String { return false }
            if let assignment = subject as? Assignment, assignment.root == "self" { return true }
            return Mirror(reflecting: subject).children.contains { walk($0.value) }
        }
        return walk(body)
    }

    /// The locals a piece of code mentions, as the frame it is run in gets them.
    private func mentioned(by subject: Any, plus roots: [String] = []) -> [TreeLocal] {
        var mentions = Mentions()
        mentions.collect(subject)
        mentions.names.formUnion(roots)
        var found: [Int: TreeLocal] = [:]
        for (slot, name) in mentions.slots {
            let known = lookup(name)
            found[slot] = TreeLocal(
                slot: Register(slot),
                name: name,
                mutable: known?.mutable ?? true,
                boxed: capturedSlots.contains(slot)
            )
        }
        for name in mentions.names {
            guard let local = lookup(name), found[Int(local.slot)] == nil else { continue }
            found[Int(local.slot)] = TreeLocal(
                slot: local.slot,
                name: name,
                mutable: local.mutable,
                boxed: local.boxed
            )
        }
        return found.values.sorted { $0.slot < $1.slot }
    }

    /// The slots a frame for these locals has: the function's locals, and any temporary one of them is
    /// (the value of an assignment, worked out first).
    private func frame(of locals: [TreeLocal]) -> Int {
        max(localCount, (locals.map { Int($0.slot) }.max() ?? -1) + 1)
    }

    /// An expression the tree evaluator runs: it is given a frame with the locals it mentions.
    mutating func treeExpression(_ expression: Expr, into destination: Register) {
        let locals = mentioned(by: expression)
        code.trees.append(
            TreeNode(source: .expression(expression), locals: locals, frameSize: frame(of: locals))
        )
        emit(.evaluateTree(dst: destination, node: UInt32(code.trees.count - 1)))
    }

    /// A statement the tree evaluator runs the same way (an assignment through a path).
    mutating func treeStatement(_ statement: Statement, roots: [String]) {
        let locals = mentioned(by: statement, plus: roots)
        code.trees.append(
            TreeNode(source: .statement(statement), locals: locals, frameSize: frame(of: locals))
        )
        emit(.runTree(node: UInt32(code.trees.count - 1)))
    }
}
