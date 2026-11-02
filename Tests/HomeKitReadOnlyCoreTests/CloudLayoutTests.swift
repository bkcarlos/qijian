import XCTest
@testable import HomeKitReadOnlyCore

final class CloudLayoutTests: XCTestCase {
    func testOfflineChangesConflictWithAnotherWriter() {
        XCTAssertEqual(CloudLayoutDecision.resolve(base: "A", remote: "B", dirty: true, hasLocal: true), .conflict)
        XCTAssertEqual(CloudLayoutDecision.resolve(base: "A", remote: "A", dirty: true, hasLocal: true), .upload)
        XCTAssertEqual(CloudLayoutDecision.resolve(base: "A", remote: "B", dirty: false, hasLocal: true), .download)
    }
    func testFirstEnableNeverSilentlyReplacesExistingLayouts() {
        XCTAssertEqual(CloudLayoutDecision.resolve(base: nil, remote: "B", dirty: false, hasLocal: true), .conflict)
        XCTAssertEqual(CloudLayoutDecision.resolve(base: nil, remote: "B", dirty: false, hasLocal: false), .download)
        XCTAssertEqual(CloudLayoutDecision.resolve(base: nil, remote: nil, dirty: false, hasLocal: true), .upload)
    }
    func testEmptyNewDeviceDoesNotCreateASeparateCloudLayout() {
        XCTAssertEqual(CloudLayoutDecision.resolve(base: nil, remote: nil, dirty: false, hasLocal: false), .unchanged)
        XCTAssertEqual(CloudLayoutDecision.resolve(base: nil, remote: nil, dirty: true, hasLocal: false), .unchanged)
        XCTAssertEqual(CloudLayoutDecision.resolve(base: "A", remote: "A", dirty: true, hasLocal: false), .upload)
    }
    func testDeletedCloudRecordRequiresExplicitRecovery() {
        XCTAssertEqual(CloudLayoutDecision.resolve(base: "A", remote: nil, dirty: false, hasLocal: true), .conflict)
        XCTAssertEqual(CloudLayoutDecision.resolve(base: "A", remote: "A", dirty: false, hasLocal: true), .unchanged)
    }
    func testDifferentAccountIDsMapOnlyUnambiguousDevices() throws {
        let source = BoardDevice(id: "old", name: "灯", homeId: "homeA", roomId: "roomA", roomName: "厨房", reachable: true, services: [])
        let target = BoardDevice(id: "new", name: "灯", homeId: "homeB", roomId: "roomB", roomName: "厨房", reachable: true, services: [])
        var plan = FloorPlanLayout(homeID: "homeA"); plan.devices["old"] = PlanPoint(x: 0.2, y: 0.4)
        let document = CloudLayoutDocument(layout: plan, homeName: "家", rooms: [], devices: [source], image: nil)
        let decoded = try CloudLayoutDocument.decode(JSONEncoder().encode(document))
        let mapped = decoded.mapped(homeID: "homeB", rooms: [], devices: [target])
        XCTAssertEqual(mapped.0.homeID, "homeB"); XCTAssertEqual(mapped.0.devices["new"], plan.devices["old"]); XCTAssertEqual(mapped.1, 0)
        var duplicate = target; duplicate.id = "another"
        let ambiguous = decoded.mapped(homeID: "homeB", rooms: [], devices: [target, duplicate])
        XCTAssertTrue(ambiguous.0.devices.isEmpty); XCTAssertEqual(ambiguous.1, 1)
        XCTAssertEqual(decoded.mapped(homeID: "homeB", rooms: [], devices: []).1, 1)
    }
    func testMalformedCloudDataCannotEscapeModelDirectory() throws {
        var document = CloudLayoutDocument(layout: FloorPlanLayout(homeID: "home"), homeName: "家", rooms: [], devices: [], image: nil)
        for path in ["../catalog.json", "/tmp/model.obj", "folder/../../secret", "folder/\\secret", "folder/https:evil"] {
            document.files = [path: Data()]
            XCTAssertThrowsError(try CloudLayoutDocument.decode(JSONEncoder().encode(document)))
        }
        document.files = [:]; document.version = 99
        XCTAssertThrowsError(try document.validate())
    }
    func testInvalidCoordinatesRejectedBeforeImport() throws {
        var plan = FloorPlanLayout(homeID: "home"); var point = PlanPoint(x: 0.5, y: 0.5); point.x = 20; plan.devices["lamp"] = point
        let document = CloudLayoutDocument(layout: plan, homeName: "家", rooms: [], devices: [], image: nil)
        XCTAssertThrowsError(try document.validate())
    }
}
