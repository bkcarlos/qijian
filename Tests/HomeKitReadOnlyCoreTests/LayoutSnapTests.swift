import XCTest
@testable import HomeKitReadOnlyCore
final class LayoutSnapTests: XCTestCase {
    func p(_ x: Double, _ y: Double) -> PlanPoint { PlanPoint(x: x, y: y) }
    func testClosurePriorityAndFixedPixelRadius() {
        let first = p(0.2,0.2)
        let hit = LayoutSnap.resolve(p(0.209,0.2), width: 1000, height: 400, anchors: [p(0.21,0.2)], edges: [], closeTo: first)
        XCTAssertEqual(hit.kind, .closure)
        XCTAssertEqual(hit.point, first)
        let zoomed = LayoutSnap.resolve(p(0.209,0.2), width: 2000, height: 800, anchors: [], edges: [], closeTo: first, grid: false)
        XCTAssertEqual(zoomed.kind, .none)
    }
    func testClosingUsesExistingStartWithoutAddingDuplicateVertex() {
        let draft = [p(0.2,0.2),p(0.8,0.2),p(0.8,0.8),p(0.2,0.8)]
        let snapped = LayoutSnap.resolve(p(0.207,0.21), width: 1000, height: 400, anchors: draft, edges: [], closeTo: draft.first)
        XCTAssertEqual(snapped.kind, .closure)
        XCTAssertTrue(SpatialRoom(id: "r", name: "r", points: draft).isValidOutline)
        XCTAssertFalse(SpatialRoom(id: "r", name: "r", points: draft + [snapped.point]).isValidOutline)
        XCTAssertFalse(SpatialRoom(id: "r", name: "r", points: [p(0,0),p(1,1),p(0,1),p(1,0)]).isValidOutline)
    }
    func testWallProjectionAlignmentAndUnsnappedPosition() {
        let wall = LayoutSnap.resolve(p(0.5,0.51), width: 1000, height: 400, anchors: [], edges: [(p(0.1,0.5),p(0.9,0.5))])
        XCTAssertEqual(wall.kind, .wall)
        XCTAssertEqual(wall.point, p(0.5,0.5))
        let aligned = LayoutSnap.resolve(p(0.305,0.7), width: 1000, height: 400, anchors: [p(0.3,0.2)], edges: [], grid: false)
        XCTAssertEqual(aligned.kind, .alignment)
        XCTAssertTrue(aligned.alignX)
        XCTAssertFalse(aligned.alignY)
        XCTAssertEqual(aligned.point, p(0.3,0.7))
        let free = LayoutSnap.resolve(p(0.5,0.7), width: 1000, height: 400, anchors: [p(0.3,0.2)], edges: [], grid: false)
        XCTAssertEqual(free.kind, .none)
        XCTAssertEqual(free.point, p(0.5,0.7))
    }
    func testVertexWinsOverWallAndGridDoesNotPullFromFarAway() {
        let hit = LayoutSnap.resolve(p(0.205,0.2), width: 1000, height: 400, anchors: [p(0.2,0.2)], edges: [(p(0,0.2),p(1,0.2))])
        XCTAssertEqual(hit.kind, .vertex)
        let grid = LayoutSnap.resolve(p(0.201,0.501), width: 1000, height: 400, anchors: [], edges: [])
        XCTAssertEqual(grid.kind, .grid)
        XCTAssertEqual(grid.point, p(0.2,0.5))
        let free = LayoutSnap.resolve(p(0.21,0.525), width: 1000, height: 400, anchors: [], edges: [])
        XCTAssertEqual(free.kind, .none)
    }
}
