import Foundation

// Foundation's String methods that come up in scripts, in plain Swift: the
// bridge reads these declarations, and Swiit calls them.
extension String {
    /// The text with every `target` replaced by `replacement`.
    public func replacingOccurrences(of target: String, with replacement: String) -> String {
        guard !target.isEmpty else { return self }
        return split(separator: target, omittingEmptySubsequences: false).joined(separator: replacement)
    }

    /// The parts of the text between the `separator`s.
    public func components(separatedBy separator: String) -> [String] {
        guard !separator.isEmpty else { return [self] }
        return split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    }
}
