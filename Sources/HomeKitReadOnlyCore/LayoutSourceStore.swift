import Foundation

public enum LayoutSource: String, Codable, CaseIterable {
    case personal, family
    public var title: String { self == .personal ? "自己的布局" : "家庭布局" }
}

/// Each source has its own layout, image and CloudKit binding. The old directory is retained.
public enum LayoutSourceStore {
    private struct Selection: Codable { var source: LayoutSource }
    private static let files = ["layout-bundle.json", "layout.json", "floorplan.jpg", "cloud-state.json"]
    public static func directory(_ source: LayoutSource, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("LayoutSources", isDirectory: true).appendingPathComponent(source.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
    public static func select(_ source: LayoutSource, in root: URL) throws {
        _ = try directory(source, in: root)
        let file = root.appendingPathComponent("layout-source.json")
        try JSONEncoder().encode(Selection(source: source)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public static func prepare(in root: URL) throws -> LayoutSource {
        let selection = root.appendingPathComponent("layout-source.json")
        if FileManager.default.fileExists(atPath: selection.path) {
            return try JSONDecoder().decode(Selection.self, from: Data(contentsOf: selection)).source
        }
        let legacyState = root.appendingPathComponent("cloud-state.json")
        var source = LayoutSource.personal
        if FileManager.default.fileExists(atPath: legacyState.path) {
            struct Legacy: Decodable { let shared: Bool }
            let legacy = try JSONDecoder().decode(Legacy.self, from: Data(contentsOf: legacyState))
            source = legacy.shared ? .family : .personal
        }
        let target = try directory(source, in: root)
        for name in files {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try Data(contentsOf: file).write(to: target.appendingPathComponent(name), options: .atomic)
            }
        }
        // Commit selection last. Interrupted migrations can be retried from the untouched legacy files.
        try select(source, in: root)
        return source
    }
}
