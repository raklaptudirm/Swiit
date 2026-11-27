import Foundation

// Executing the instructions that make a value of another kind or type.

extension Interpreter {
    func executeConversions(
        _ instruction: Instruction.Conversions,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        var regs = stack.base + cursor.base
        let (code, base) = (cursor.code, cursor.base)
        switch instruction {
        case .interpolate(let dst, let siteIndex, let first):
            var text = ""
            for piece in cursor.code.strings[Int(siteIndex)].pieces {
                switch piece {
                case .text(let literal): text += literal
                case .value(let index): text += try describing(regs[Int(first) + index])
                }
            }
            regs = stack.base + cursor.base
            regs[Int(dst)] = .string(text)
        case .requireValue(let src, let message):
            if regs[Int(src)] == .nothing { throw RuntimeError(cursor.code.names[Int(message)]) }
        case .describe(let dst, let src, let type):
            let text = try describing(regs[Int(src)], type: cursor.code.types[Int(type)])
            stack.base[cursor.base + Int(dst)] = .string(text)
        case .cast(let dst, let src, let type, let kind):
            let value = regs[Int(src)]
            let expected = cursor.code.types[Int(type)]
            let converted = conform(value, to: expected)
            let result: Value
            switch kind {
            case .conditional: result = converted ?? .nothing
            case .check: result = .bool(converted != nil)
            case .upcast: result = converted ?? value
            case .forced:
                guard let converted else {
                    throw RuntimeError("'as!' failed: a \(value.typeName) isn't a \(expected)")
                }
                result = converted
            }
            stack.base[cursor.base + Int(dst)] = result
        case .conform(let dst, let src, let type):
            let value = stack.base[base + Int(src)]
            let expected = code.types[Int(type)]
            guard let conforming = conform(value, to: expected) else {
                throw RuntimeError("expected \(expected), not \(value.typeName)")
            }
            stack.base[base + Int(dst)] = conforming
        }
    }
}
