import Foundation

/// Normalized image coordinates, shared by the tracing editor and the 3D world.
public struct SpatialRoom: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var points: [PlanPoint]
    public var wallHeight: Double = 0.8
    public init(id: String, name: String, points: [PlanPoint]) { self.id = id; self.name = name; self.points = points }
    public var isValidOutline: Bool {
        guard points.count >= 3 else { return false }
        var area = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i+1)%points.count]
            if abs(a.x-b.x)+abs(a.y-b.y) < 0.0001 { return false }
            area += a.x*b.y-b.x*a.y
        }
        guard abs(area) > 0.00001 else { return false }
        func cross(_ a: PlanPoint, _ b: PlanPoint, _ c: PlanPoint) -> Double { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
        for i in points.indices { for j in points.indices where j > i+1 && !(i == 0 && j == points.count-1) {
            let a = points[i], b = points[(i+1)%points.count], c = points[j], d = points[(j+1)%points.count]
            if cross(a,b,c)*cross(a,b,d) <= 0 && cross(c,d,a)*cross(c,d,b) <= 0,
               max(min(a.x,b.x),min(c.x,d.x)) <= min(max(a.x,b.x),max(c.x,d.x)),
               max(min(a.y,b.y),min(c.y,d.y)) <= min(max(a.y,b.y),max(c.y,d.y)) { return false }
        } }
        return true
    }
    public struct WallHit {
        public let edge: Int
        public let fraction: Double
        public let distance: Double
    }
    /// Distances are measured in rendered pixels, not normalized image coordinates.
    public func nearestWall(x: Double, y: Double, width: Double, height: Double) -> WallHit? {
        guard width > 0, height > 0, x.isFinite, y.isFinite, points.count >= 3 else { return nil }
        return points.indices.compactMap { i -> WallHit? in
            let a = points[i], b = points[(i + 1) % points.count]
            let dx = (b.x-a.x)*width, dy = (b.y-a.y)*height
            let lengthSquared = dx*dx + dy*dy
            guard lengthSquared > 0 else { return nil }
            let t = min(1, max(0, ((x-a.x*width)*dx + (y-a.y*height)*dy)/lengthSquared))
            return WallHit(edge: i, fraction: t, distance: hypot(x-a.x*width-t*dx, y-a.y*height-t*dy))
        }.min { $0.distance < $1.distance }
    }
    public func insertingVertex(on edge: Int, fraction: Double) throws -> SpatialRoom {
        guard points.indices.contains(edge), fraction.isFinite, fraction > 0, fraction < 1 else {
            throw CommandFailure("invalid_wall_point", "请在墙体中间添加角点，避开已有角点。")
        }
        guard points.count < 100 else { throw CommandFailure("vertex_limit", "每个房间最多支持 100 个角点。") }
        let a = points[edge], b = points[(edge + 1) % points.count]
        var result = self
        result.points.insert(PlanPoint(x: a.x + (b.x-a.x)*fraction, y: a.y + (b.y-a.y)*fraction), at: edge + 1)
        guard result.isValidOutline else { throw CommandFailure("invalid_outline", "新增角点过近或轮廓无效，请换一个位置。") }
        return result
    }
    public func removingVertex(at index: Int) throws -> SpatialRoom {
        guard points.indices.contains(index) else { throw CommandFailure("vertex_changed", "角点已变化，请重新选择。") }
        guard points.count > 3 else { throw CommandFailure("minimum_vertices", "房间至少需要保留 3 个角点。") }
        var result = self
        result.points.remove(at: index)
        guard result.isValidOutline else { throw CommandFailure("invalid_outline", "删除后墙体会交叉或连成直线，请先调整相邻角点。") }
        return result
    }
    public var center: PlanPoint {
        PlanPoint(x: points.map(\.x).reduce(0,+) / Double(max(1, points.count)), y: points.map(\.y).reduce(0,+) / Double(max(1, points.count)))
    }
    public func contains(_ point: PlanPoint) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false; var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x-a.x) * (point.y-a.y) / (b.y-a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
public struct SpatialFurniture: Codable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var kind: String
    public var assetID: String? = nil
    public var point: PlanPoint
    public var width: Double = 0.08
    public var depth: Double = 0.1
    public var rotation: Double = 0
    public init(kind: String, point: PlanPoint, width: Double = 0.08, depth: Double = 0.1, rotation: Double = 0) {
        self.kind = kind; self.point = point; self.width = width; self.depth = depth; self.rotation = rotation
    }
    public static let kinds = ["bed", "sofa", "table", "cabinet", "plant", "bath", "toilet", "sink", "stove", "fridge", "counter", "rangeHood"]
    public static func title(_ kind: String) -> String { ["bed":"床", "sofa":"沙发", "table":"桌子", "cabinet":"柜体", "plant":"绿植", "bath":"卫浴", "toilet":"马桶", "sink":"洗手池", "stove":"灶具", "fridge":"冰箱", "counter":"橱柜", "rangeHood":"油烟机"][kind] ?? "家具" }
    public static func icon(_ kind: String) -> String { ["bed":"bed.double.fill", "sofa":"sofa.fill", "table":"table.furniture.fill", "cabinet":"cabinet.fill", "plant":"leaf.fill", "bath":"bathtub.fill", "toilet":"toilet.fill", "sink":"sink.fill", "stove":"flame.fill", "fridge":"refrigerator.fill", "counter":"cabinet.fill", "rangeHood":"fan.fill"][kind] ?? "cube.fill" }
}
public struct SpatialLayout: Codable, Equatable {
    public var rooms: [SpatialRoom] = []
    public var furniture: [SpatialFurniture] = []
    public init() {}
    public func validate() throws {
        func valid(_ p: PlanPoint) -> Bool { p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y) }
        guard rooms.count <= 100, furniture.count <= 500,
              Set(rooms.map(\.id)).count == rooms.count, Set(furniture.map(\.id)).count == furniture.count,
              rooms.allSatisfy({ $0.points.count <= 100 && $0.isValidOutline && $0.points.allSatisfy(valid) && $0.wallHeight.isFinite && (0.1...3).contains($0.wallHeight) }),
              furniture.allSatisfy({ valid($0.point) && Self.validFurniture($0) }) else { throw CommandFailure("invalid_spatial_layout", "空间布局的坐标、尺寸或组件无效") }
    }
    private static func validFurniture(_ f: SpatialFurniture) -> Bool {
        ((SpatialFurniture.kinds.contains(f.kind) && f.assetID == nil) || (f.kind == "model" && f.assetID.map(FurnitureAsset.validID) == true)) && f.width.isFinite && f.depth.isFinite && (0.005...1).contains(f.width) && (0.005...1).contains(f.depth) && f.rotation.isFinite
    }
}

public struct SpatialCalibration: Codable {
    public var version: Int
    public var rooms: [SpatialRoom]
    public var furniture: [SpatialFurniture]
    public var placeDevices: Bool
}
