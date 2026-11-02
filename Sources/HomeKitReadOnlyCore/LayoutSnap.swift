import Foundation

public struct LayoutSnapResult {
    public enum Kind: String { case none, vertex, wall, alignment, grid, closure }
    public let point: PlanPoint
    public let kind: Kind
    public let alignX: Bool
    public let alignY: Bool
    public var label: String {
        switch kind {
        case .none: return ""
        case .vertex: return "吸附角点"
        case .wall: return "吸附墙边"
        case .alignment: return "对齐角点"
        case .grid: return "吸附网格"
        case .closure: return "点击闭合房间"
        }
    }
}
public enum LayoutSnap {
    public static func resolve(_ point: PlanPoint, width: Double, height: Double,
                               anchors: [PlanPoint], edges: [(PlanPoint, PlanPoint)],
                               closeTo: PlanPoint? = nil, grid: Bool = true) -> LayoutSnapResult {
        func result(_ p: PlanPoint, _ kind: LayoutSnapResult.Kind, _ x: Bool = false, _ y: Bool = false) -> LayoutSnapResult {
            LayoutSnapResult(point: p, kind: kind, alignX: x, alignY: y)
        }
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return result(point, .none) }
        func distance(_ p: PlanPoint) -> Double { hypot((p.x-point.x)*width, (p.y-point.y)*height) }
        if let first = closeTo, distance(first) <= 14 { return result(first, .closure, true, true) }
        if let vertex = anchors.min(by: { distance($0) < distance($1) }), distance(vertex) <= 12 {
            return result(vertex, .vertex, true, true)
        }
        let walls = edges.compactMap { a, b -> (PlanPoint, Double)? in
            let dx = (b.x-a.x)*width, dy = (b.y-a.y)*height
            let length = dx*dx + dy*dy
            guard length > 0 else { return nil }
            let t = min(1, max(0, ((point.x-a.x)*width*dx + (point.y-a.y)*height*dy)/length))
            let projected = PlanPoint(x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t)
            return (projected, distance(projected))
        }
        if let wall = walls.min(by: { $0.1 < $1.1 }), wall.1 <= 10 { return result(wall.0, .wall) }
        let xAnchor = anchors.min { abs($0.x-point.x) < abs($1.x-point.x) }
        let yAnchor = anchors.min { abs($0.y-point.y) < abs($1.y-point.y) }
        let alignX = xAnchor.map { abs($0.x-point.x)*width <= 8 } ?? false
        let alignY = yAnchor.map { abs($0.y-point.y)*height <= 8 } ?? false
        var x = alignX ? xAnchor!.x : point.x, y = alignY ? yAnchor!.y : point.y
        var gridded = false
        if grid {
            let stepY = 0.02*width/height
            let gx = (point.x/0.02).rounded()*0.02, gy = (point.y/stepY).rounded()*stepY
            if !alignX, abs(gx-point.x)*width <= 6 { x = gx; gridded = true }
            if !alignY, abs(gy-point.y)*height <= 6 { y = gy; gridded = true }
        }
        return result(PlanPoint(x: x, y: y), alignX || alignY ? .alignment : gridded ? .grid : .none, alignX, alignY)
    }
}
