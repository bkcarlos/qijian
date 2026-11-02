import Foundation

/// Maps normalized layout coordinates to pixels. 2D edits use the same values as 3D.
public struct PlanViewport: Equatable {
    public var zoom = 1.0
    public var offsetX = 0.0
    public var offsetY = 0.0
    public init() {}
}
public struct PlanProjection {
    public var imageWidth: Double
    public var imageHeight: Double
    public var width: Double
    public var height: Double
    public var fitX: Double
    public var fitY: Double
    public var baseScale: Double
    public var quarterTurns: Int
    public var rotation: Double { Double(quarterTurns) * .pi / 2 }
    public var state: PlanViewport
    public init(imageWidth: Double, imageHeight: Double, width: Double, height: Double, points: [PlanPoint], state: PlanViewport, quarterTurns: Int? = 0, padding: Double = 32) {
        self.imageWidth = max(1,imageWidth); self.imageHeight = max(1,imageHeight)
        self.width = max(1,width); self.height = max(1,height); self.state = state
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 1
        fitX = (minX+maxX)/2; fitY = (minY+maxY)/2
        let spanX = max(0.1,maxX-minX)*self.imageWidth, spanY = max(0.1,maxY-minY)*self.imageHeight
        let availableX = max(1,width-2*padding), availableY = max(1,height-2*padding)
        let normal = min(availableX/spanX, availableY/spanY)
        let rotated = min(availableX/spanY, availableY/spanX)
        let turns = quarterTurns ?? (rotated > normal * 1.05 ? 1 : 0)
        self.quarterTurns = ((turns % 4) + 4) % 4
        baseScale = self.quarterTurns % 2 == 0 ? normal : rotated
    }
    public var scale: Double { baseScale * state.zoom }
    public func screen(_ p: PlanPoint) -> (x: Double,y: Double) {
        let dx = (p.x-fitX-state.offsetX)*imageWidth*scale, dy = (p.y-fitY-state.offsetY)*imageHeight*scale
        let rotated = rotate(dx,dy,turns:quarterTurns)
        return (rotated.x+width/2,rotated.y+height/2)
    }
    public func rawPoint(x: Double,y: Double) -> (x: Double,y: Double) {
        let local = rotate(x-width/2,y-height/2,turns:(4-quarterTurns)%4)
        return (local.x/(imageWidth*scale)+fitX+state.offsetX,local.y/(imageHeight*scale)+fitY+state.offsetY)
    }
    private func rotate(_ x:Double,_ y:Double,turns:Int) -> (x:Double,y:Double) {
        switch turns { case 1: return (-y,x); case 2: return (-x,-y); case 3: return (y,-x); default: return (x,y) }
    }
    public func point(x: Double,y: Double,snap: Bool = false) -> PlanPoint {
        var p = rawPoint(x:x,y:y)
        if snap { let stepY = 0.02*imageWidth/imageHeight; p.x = (p.x/0.02).rounded()*0.02; p.y = (p.y/stepY).rounded()*stepY }
        return PlanPoint(x:p.x,y:p.y)
    }
    public func zoomed(factor: Double, aroundX x: Double, y: Double) -> PlanViewport {
        guard factor.isFinite, factor > 0 else { return state }
        let anchor = rawPoint(x:x,y:y)
        var changed = self; changed.state.zoom = min(6,max(0.35,state.zoom*factor))
        let after = changed.rawPoint(x:x,y:y)
        changed.state.offsetX += anchor.x-after.x; changed.state.offsetY += anchor.y-after.y
        return changed.state
    }
    public func panned(dx: Double,dy: Double) -> PlanViewport {
        guard dx.isFinite,dy.isFinite else { return state }
        var result = state
        let delta = rotate(dx,dy,turns:(4-quarterTurns)%4)
        result.offsetX = min(2,max(-2,result.offsetX-delta.x/(imageWidth*scale)))
        result.offsetY = min(2,max(-2,result.offsetY-delta.y/(imageHeight*scale)))
        return result
    }
    public func furnitureLocal(_ f: SpatialFurniture,x: Double,y: Double) -> (x:Double,y:Double) {
        let center = screen(f.point), angle = f.rotation * .pi/180 + rotation
        let dx = x-center.x, dy = y-center.y
        return (dx*cos(angle)+dy*sin(angle),-dx*sin(angle)+dy*cos(angle))
    }
    public func hits(_ f: SpatialFurniture,x:Double,y:Double) -> Bool {
        let local = furnitureLocal(f,x:x,y:y)
        return abs(local.x) <= max(8,f.width*imageWidth*scale/2) && abs(local.y) <= max(8,f.depth*imageHeight*scale/2)
    }
}
