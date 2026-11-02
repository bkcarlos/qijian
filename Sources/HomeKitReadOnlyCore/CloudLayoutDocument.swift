import Foundation

/// A layout-only payload. No HomeKit values, credentials, scenes or camera content are uploaded.
public struct CloudLayoutDocument: Codable {
    public var version = 1
    public var layout: FloorPlanLayout
    public var homeName: String
    public var rooms: [Room]
    public var devices: [Device]
    public var image: Data?
    public var models: [FurnitureAsset] = []
    public var files: [String: Data] = [:]
    public struct Room: Codable { public var id: String; public var name: String }
    public struct Device: Codable { public var id: String; public var name: String; public var roomName: String }
    public init(layout: FloorPlanLayout, homeName: String, rooms: [BoardRoom], devices: [BoardDevice], image: Data?) {
        self.layout = layout; self.homeName = homeName; self.image = image
        self.rooms = rooms.map { Room(id: $0.id, name: $0.name) }
        self.devices = devices.filter { layout.devices[$0.id] != nil }.map { Device(id: $0.id, name: $0.name, roomName: $0.roomName) }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 150_000_000 else { throw CommandFailure("cloud_size", "共享布局过大") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
    public func validate() throws {
        guard version == 1, (image?.count ?? 0) <= 30_000_000,
              models.count <= 100, files.count <= 1000,
              files.values.reduce(0, { $0 + $1.count }) <= 100_000_000,
              Set(models.map(\.id)).count == models.count,
              rooms.count <= 200, devices.count <= 2000 else { throw CommandFailure("cloud_size", "共享布局格式或大小不受支持") }
        _ = try FloorPlanLayout.decode(JSONEncoder().encode(layout), homeID: layout.homeID)
        for path in files.keys {
            guard Self.safePath(path) else { throw CommandFailure("cloud_path", "模型包含不安全的文件路径") }
        }
        for asset in models {
            guard asset.isCustom, FurnitureAsset.validID(asset.id), asset.width.isFinite, asset.depth.isFinite,
                  asset.width > 0, asset.depth > 0, Self.safePath(asset.file), Self.safePath(asset.preview),
                  files[asset.file] != nil, files[asset.preview] != nil else { throw CommandFailure("cloud_model", "共享模型文件不完整") }
        }
    }
    public static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") && !$0.contains("\0") }
    }
    /// Accounts can expose different HomeKit IDs. Only unambiguous matches become controls.
    public func mapped(homeID: String, rooms localRooms: [BoardRoom], devices localDevices: [BoardDevice]) -> (FloorPlanLayout, Int) {
        var result = layout; result.homeID = homeID; result.devices = [:]; result.rooms = [:]
        var missing = 0, roomIDs: [String: String] = [:]
        for room in rooms {
            let matches = localRooms.filter { $0.name == room.name }
            if let exact = localRooms.first(where: { $0.id == room.id }) { roomIDs[room.id] = exact.id }
            else if matches.count == 1 { roomIDs[room.id] = matches[0].id }
        }
        for (id, point) in layout.rooms { if let local = roomIDs[id] { result.rooms[local] = point } }
        for i in result.spatial?.rooms.indices ?? 0..<0 {
            if let id = result.spatial?.rooms[i].id, let local = roomIDs[id] { result.spatial?.rooms[i].id = local }
        }
        for (id, point) in layout.devices {
            if localDevices.contains(where: { $0.id == id }) { result.devices[id] = point; continue }
            guard let original = devices.first(where: { $0.id == id }) else { missing += 1; continue }
            let matches = localDevices.filter { $0.name == original.name && $0.roomName == original.roomName }
            if matches.count == 1, result.devices[matches[0].id] == nil { result.devices[matches[0].id] = point }
            else { missing += 1 }
        }
        return (result, missing)
    }
}

public enum CloudLayoutDecision: Equatable {
    case upload, download, unchanged, conflict
    public static func resolve(base: String?, remote: String?, dirty: Bool, hasLocal: Bool) -> Self {
        if remote == nil { return base == nil ? (hasLocal ? .upload : .unchanged) : .conflict }
        if dirty { return base == remote ? .upload : .conflict }
        if base == nil && hasLocal { return .conflict }
        return base == remote ? .unchanged : .download
    }
}
