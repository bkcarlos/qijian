import XCTest
@testable import HomeKitReadOnlyCore

final class SpatialLayoutTests: XCTestCase {
    func point(_ x: Double,_ y: Double) -> PlanPoint { PlanPoint(x:x,y:y) }
    func testInsertWallVertexProjectsInScreenSpaceAndHandlesClosingEdge() throws {
        let room = SpatialRoom(id: "r", name: "客厅", points: [point(0,0), point(1,0), point(1,1), point(0,1)])
        let hit = try XCTUnwrap(room.nearestWall(x: 30, y: 160, width: 1000, height: 200))
        XCTAssertEqual(hit.edge, 3)
        XCTAssertEqual(hit.distance, 30, accuracy: 0.001)
        let added = try room.insertingVertex(on: hit.edge, fraction: hit.fraction)
        XCTAssertEqual(added.points.count, 5)
        XCTAssertEqual(added.points[4].x, 0)
        XCTAssertEqual(added.points[4].y, 0.8, accuracy: 0.001)
        XCTAssertEqual(try added.removingVertex(at: 4), room)
        XCTAssertTrue(added.isValidOutline)
        XCTAssertEqual(try room.insertingVertex(on: 0, fraction: 0.25).points[1], point(0.25,0))
        XCTAssertThrowsError(try room.insertingVertex(on: 0, fraction: 0))
        XCTAssertThrowsError(try room.insertingVertex(on: 4, fraction: 0.5))
        XCTAssertThrowsError(try room.insertingVertex(on: 0, fraction: .nan))
        XCTAssertThrowsError(try room.insertingVertex(on: 0, fraction: 0.000001))
    }
    func testRemoveVertexPreservesRoomMetadataAndRejectsInvalidOutline() throws {
        var room = SpatialRoom(id: "room", name: "客厅", points: [point(0,0), point(0.5,0), point(1,0), point(1,1), point(0,1)])
        room.wallHeight = 1.2
        let edited = try room.removingVertex(at: 1)
        XCTAssertEqual(edited.points, [point(0,0), point(1,0), point(1,1), point(0,1)])
        XCTAssertEqual(edited.wallHeight, 1.2)
        XCTAssertEqual(edited.id, room.id)
        XCTAssertEqual(room.points.count, 5)
        XCTAssertThrowsError(try room.removingVertex(at: 20))
        let triangle = try edited.removingVertex(at: 1)
        XCTAssertThrowsError(try triangle.removingVertex(at: 0))
        let collinear = SpatialRoom(id: "r", name: "r", points: [point(0,0), point(0.5,0.5), point(1,1), point(0,1)])
        XCTAssertTrue(collinear.isValidOutline)
        XCTAssertThrowsError(try collinear.removingVertex(at: 3))
    }
    func testLegacyLayoutStillLoadsAnd3DRoundTrips() throws {
        let old = Data(#"{"version":1,"homeID":"home","devices":{"lamp":{"x":0.3,"y":0.4}},"rooms":{}}"#.utf8)
        var layout = try FloorPlanLayout.decode(old,homeID:"home")
        XCTAssertNil(layout.spatial)
        var spatial = SpatialLayout()
        spatial.rooms = [SpatialRoom(id:"living",name:"客厅",points:[point(0,0),point(1,0),point(1,1),point(0,1)])]
        spatial.furniture = [SpatialFurniture(kind:"bed",point:point(0.5,0.5),rotation:90),
                             SpatialFurniture(kind:"bath",point:point(0.2,0.2)),
                             SpatialFurniture(kind:"toilet",point:point(0.3,0.2),width:0.04,depth:0.08),
                             SpatialFurniture(kind:"sink",point:point(0.4,0.2),width:0.06,depth:0.05)]
        spatial.furniture += ["stove", "fridge", "counter", "rangeHood"].map { SpatialFurniture(kind:$0,point:point(0.6,0.6)) }
        try spatial.validate()
        layout.spatial = spatial
        XCTAssertEqual(try FloorPlanLayout.decode(JSONEncoder().encode(layout),homeID:"home"),layout)
        XCTAssertEqual(layout.devices["lamp"],point(0.3,0.4))
    }
    func testConcaveRoomMembershipAndInvalidWalls() throws {
        let l = SpatialRoom(id:"l",name:"客厅",points:[point(0,0),point(0.5,0),point(0.5,0.5),point(1,0.5),point(1,1),point(0,1)])
        XCTAssertTrue(l.isValidOutline)
        XCTAssertTrue(l.contains(point(0.25,0.25)))
        XCTAssertTrue(l.contains(point(0.75,0.75)))
        XCTAssertFalse(l.contains(point(0.75,0.25)))
        let crossed = SpatialRoom(id:"x",name:"invalid",points:[point(0,0),point(1,1),point(1,0),point(0,1)])
        XCTAssertFalse(crossed.isValidOutline)
        let degenerate = SpatialRoom(id:"x",name:"invalid",points:[point(0,0),point(0.5,0.5),point(1,1)])
        XCTAssertFalse(degenerate.isValidOutline)
        var spatial = SpatialLayout(); spatial.rooms = [crossed]
        XCTAssertThrowsError(try spatial.validate())
    }
    func testRejectsInvalidFurnitureAndDuplicateIDs() throws {
        var spatial = SpatialLayout()
        var f = SpatialFurniture(kind:"bed",point:point(0.5,0.5)); f.width = -1
        spatial.furniture = [f]; XCTAssertThrowsError(try spatial.validate())
        f.width = 0.1; spatial.furniture = [f,f]; XCTAssertThrowsError(try spatial.validate())
        f.kind = "unknown"; spatial.furniture = [f]; XCTAssertThrowsError(try spatial.validate())
    }
}
