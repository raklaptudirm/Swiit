/// The locals of one run of a function, a closure or a program: a slot for each local, which the
/// variable in it is put in when it is bound and taken out of when its block ends. A slot is
/// given once for each place a local is declared (`FrameResolver`), and blocks side by side share
/// them, so a frame is as big as the most locals alive at once.
///
/// A local is still found by its name: the frame is asked before the scopes made before it, and
/// after those made since (the bindings of an `if` expression, a `case`'s `where`). Of two locals of
/// one name, the later slot is the inner one, which shadows the other.
///
/// A frame is the run's alone: what a closure keeps is the variables in it, never the frame, so
/// one whose run has ended is emptied and used again (`TaskContext.spareFrames`).
final class Frame {
    private var slots: ContiguousArray<(name: String, binding: Binding)?>
    /// How many of `slots` this run uses: a frame used again may have more.
    private var size: Int

    init(size: Int) {
        slots = ContiguousArray(repeating: nil, count: size)
        self.size = size
    }

    /// Ready for a run of `size` slots, all empty.
    func reset(size: Int) {
        if slots.count < size {
            slots.append(contentsOf: repeatElement(nil, count: size - slots.count))
        }
        self.size = size
    }

    /// Its run has ended: nothing it held is kept.
    func empty() {
        for index in 0..<size { slots[index] = nil }
    }

    func bind(_ name: String, _ binding: Binding, at slot: Int) {
        slots[slot] = (name, binding)
    }

    /// What is in a slot now.
    func binding(at slot: Int) -> Binding? {
        slots[slot]?.binding
    }

    /// The block whose locals these are has ended.
    func clear(_ locals: [Program.Local]) {
        for local in locals { slots[local.slot] = nil }
    }

    /// The innermost local of that name alive now.
    func binding(named name: String) -> Binding? {
        var index = size - 1
        while index >= 0 {
            if let local = slots[index], local.name == name { return local.binding }
            index -= 1
        }
        return nil
    }
}
