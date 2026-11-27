import Foundation

// Executing the instructions that read and set global variables through the cells the loop keeps
// for them.

extension Interpreter {
    func executeGlobals(
        _ instruction: Instruction.Globals,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let (function, code, base) = (cursor.function, cursor.code, cursor.base)
        switch instruction {
        case .loadGlobal(let dst, let siteIndex):
            unowned(unsafe) let site = code.globalTable[Int(siteIndex)].takeUnretainedValue()
            if site.version == scopeVersion, site.function == ObjectIdentifier(function),
                let cell = site.cell
            {
                let value = cell.value
                if case .object(is WeakReference) = value.storage {
                } else {
                    stack.base[base + Int(dst)] = value
                    return
                }
            }
            let value = try globalValue(site, function, code)
            stack.base[base + Int(dst)] = value
        case .assignGlobal(let global, let assignmentIndex, let value):
            unowned(unsafe) let site = code.globalTable[Int(global)].takeUnretainedValue()
            if site.version == scopeVersion, site.function == ObjectIdentifier(function),
                site.isMutable, let cell = site.cell,
                setNumber(
                    in: cell,
                    code.assignments[Int(assignmentIndex)].op,
                    to: stack.base[base + Int(value)]
                )
            {
                return
            }
            let assignment = code.assignments[Int(assignmentIndex)]
            try assignGlobal(site, assignment, stack.base[base + Int(value)], function, code)
        }
    }
}
