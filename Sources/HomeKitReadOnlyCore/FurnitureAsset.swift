import Foundation

public struct FurnitureAsset: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var category: String
    public var file: String
    public var preview: String
    public var width: Double
    public var depth: Double
    public var keywords: String
    public var isCustom: Bool { id.hasPrefix("custom:") }
    public func matches(_ query: String, category selected: String) -> Bool {
        (selected == "全部" || category == selected || (selected == "我的模型" && isCustom)) &&
        (query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ||
         (title + " " + category + " " + keywords).localizedStandardContains(query.trimmingCharacters(in:.whitespacesAndNewlines)))
    }
    public static func validID(_ id: String) -> Bool {
        id.range(of:"^(kenney|custom):[A-Za-z0-9_-]{1,100}$",options:.regularExpression) != nil
    }
}
