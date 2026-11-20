import Foundation

/// A Swift type that answers for members it only knows at run time, such as the keys of a parsed
/// object. A script reads them as it reads registered members, and a host that lays values out as
/// records finds their names here.
public protocol DynamicMembers {
    /// The names of the members it answers for, in order.
    var memberNames: [String] { get }
    /// A member answered at run time, after the registered ones; nil if there is none.
    func member(_ name: String) -> Value?
}
