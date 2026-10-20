import Foundation

extension Value {
    /// How it looks, beyond its text: plain for anything that doesn't say.
    var displayShape: DisplayShape {
        if case .object(let box as SwiftValue) = self, let displayed = box.value as? any SwiitDisplayed {
            return displayed.swiitShape
        }
        return DisplayShape()
    }
}

