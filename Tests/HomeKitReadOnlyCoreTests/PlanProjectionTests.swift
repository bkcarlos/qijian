import XCTest
@testable import HomeKitReadOnlyCore
final class PlanProjectionTests: XCTestCase {
    func projection(_ state:PlanViewport = PlanViewport()) -> PlanProjection {
        PlanProjection(imageWidth:1000,imageHeight:750,width:800,height:600,points:[PlanPoint(x:0.3,y:0.1),PlanPoint(x:0.7,y:0.9)],state:state)
    }
    func testCoordinateRoundTripAfterZoomAndPan() {
        let first = projection(); let point = PlanPoint(x:0.4,y:0.3), pixel = first.screen(point)
        let zoom = first.zoomed(factor:2,aroundX:pixel.x,y:pixel.y)
        let enlarged = projection(zoom), anchored = enlarged.screen(point)
        XCTAssertEqual(anchored.x,pixel.x,accuracy:0.00001); XCTAssertEqual(anchored.y,pixel.y,accuracy:0.00001)
        let moved = projection(enlarged.panned(dx:80,dy:-20)), at = moved.screen(point)
        XCTAssertEqual(at.x,pixel.x+80,accuracy:0.00001); XCTAssertEqual(at.y,pixel.y-20,accuracy:0.00001)
        let restored = moved.point(x:at.x,y:at.y)
        XCTAssertEqual(restored.x,point.x,accuracy:0.00001); XCTAssertEqual(restored.y,point.y,accuracy:0.00001)
    }
    func testRotatedFurnitureHitUsesPhysicalAspectRatio() {
        let p = projection(), f = SpatialFurniture(kind:"sofa",point:PlanPoint(x:0.5,y:0.5),width:0.2,depth:0.04,rotation:90)
        let center = p.screen(f.point)
        XCTAssertTrue(p.hits(f,x:center.x,y:center.y+70*p.scale))
        XCTAssertFalse(p.hits(f,x:center.x+70*p.scale,y:center.y))
    }
    func testSnapBoundsAndZoomLimits() {
        let p = projection()
        XCTAssertEqual(p.point(x:-10000,y:-10000),PlanPoint(x:0,y:0))
        XCTAssertEqual(p.zoomed(factor:100,aroundX:400,y:300).zoom,6)
        XCTAssertEqual(p.zoomed(factor:Double.nan,aroundX:0,y:0),p.state)
        let xy = p.screen(PlanPoint(x:0.413,y:0.381)), snap = p.point(x:xy.x,y:xy.y,snap:true)
        XCTAssertEqual(snap.x,0.42,accuracy:0.00001)
        XCTAssertEqual(snap.y/(0.02*1000/750),(snap.y/(0.02*1000/750)).rounded(),accuracy:0.00001)
    }
    func testAutomaticOrientationMaximizesVisibleScale() {
        let points = [PlanPoint(x:0.4,y:0.05),PlanPoint(x:0.6,y:0.95)]
        let landscape = PlanProjection(imageWidth:1000,imageHeight:1000,width:800,height:300,points:points,state:PlanViewport(),quarterTurns:nil)
        let portrait = PlanProjection(imageWidth:1000,imageHeight:1000,width:300,height:800,points:points,state:PlanViewport(),quarterTurns:nil)
        XCTAssertEqual(landscape.quarterTurns,1)
        XCTAssertEqual(portrait.quarterTurns,0)
        for p in points {
            let at = landscape.screen(p)
            XCTAssertGreaterThanOrEqual(at.x,31.999); XCTAssertLessThanOrEqual(at.x,768.001)
            XCTAssertGreaterThanOrEqual(at.y,31.999); XCTAssertLessThanOrEqual(at.y,268.001)
        }
    }
    func testEveryViewingRotationPreservesCoordinatesZoomAndPan() {
        for turn in 0..<4 {
            let p = PlanProjection(imageWidth:1000,imageHeight:750,width:400,height:650,points:[],state:PlanViewport(),quarterTurns:turn)
            let point = PlanPoint(x:0.4,y:0.3), at = p.screen(point)
            let decoded = p.point(x:at.x,y:at.y)
            XCTAssertEqual(decoded.x,point.x,accuracy:0.000001); XCTAssertEqual(decoded.y,point.y,accuracy:0.000001)
            var zoomed = p; zoomed.state = p.zoomed(factor:1.8,aroundX:at.x,y:at.y)
            XCTAssertEqual(zoomed.screen(point).x,at.x,accuracy:0.000001); XCTAssertEqual(zoomed.screen(point).y,at.y,accuracy:0.000001)
            var moved = p; moved.state = p.panned(dx:20,dy:-30)
            XCTAssertEqual(moved.screen(point).x,at.x+20,accuracy:0.000001); XCTAssertEqual(moved.screen(point).y,at.y-30,accuracy:0.000001)
            let furniture = SpatialFurniture(kind:"sofa",point:point,width:0.2,depth:0.04,rotation:0)
            let dx = cos(p.rotation)*70*p.scale, dy = sin(p.rotation)*70*p.scale
            XCTAssertTrue(p.hits(furniture,x:at.x+dx,y:at.y+dy))
            XCTAssertFalse(p.hits(furniture,x:at.x-dy,y:at.y+dx))
        }
    }

}
