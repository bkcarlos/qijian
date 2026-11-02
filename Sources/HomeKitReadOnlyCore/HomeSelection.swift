import Foundation

/// A remembered home is only usable while HomeKit still grants access to it.
public enum HomeSelection {
    public static func resolve(available: [String], current: String, remembered: String?) -> String? {
        if available.contains(current) { return current }
        if let remembered, available.contains(remembered) { return remembered }
        return available.first
    }
}
