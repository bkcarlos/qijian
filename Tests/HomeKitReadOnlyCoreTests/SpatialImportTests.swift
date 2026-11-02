import XCTest
@testable import HomeKitReadOnlyCore

final class SpatialImportTests: XCTestCase {
    var sample: Data { Data(SpatialImportGuide.example.utf8) }
    func modified(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: sample) as? [String: Any]); edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    func testPublishedExampleAndExistingV1FormatDecode() throws {
        let input = try SpatialCalibration.decode(sample)
        XCTAssertEqual(input.version, 1); XCTAssertEqual(input.rooms.count, 1); XCTAssertEqual(input.furniture.count, 2)
        XCTAssertEqual(input.rooms[0].name, "客厅")
        XCTAssertEqual(try SpatialCalibration.decode(JSONEncoder().encode(input)).rooms, input.rooms)
    }
    func testRejectsMissingFieldsUnknownFieldsAndWrongVersion() throws {
        XCTAssertThrowsError(try SpatialCalibration.decode(modified { $0.removeValue(forKey: "placeDevices") }))
        XCTAssertThrowsError(try SpatialCalibration.decode(modified { $0["version"] = 2 }))
        XCTAssertThrowsError(try SpatialCalibration.decode(modified { $0["devices"] = [:] }))
        XCTAssertThrowsError(try SpatialCalibration.decode(modified {
            var furniture = $0["furniture"] as! [[String: Any]]; furniture[0]["angle"] = 90; $0["furniture"] = furniture
        }))
        XCTAssertThrowsError(try SpatialCalibration.decode(Data("```json\n{}\n```".utf8)))
        XCTAssertThrowsError(try SpatialCalibration.decode(Data(repeating: 32, count: 2_000_000)))
    }
    func testRejectsRawOutOfRangeCoordinatesAndInvalidPolygons() throws {
        XCTAssertThrowsError(try SpatialCalibration.decode(modified {
            var rooms = $0["rooms"] as! [[String: Any]]; rooms[0]["points"] = [["x": -0.1, "y": 0.1], ["x": 0.9, "y": 0.1], ["x": 0.9, "y": 0.9]]; $0["rooms"] = rooms
        }))
        XCTAssertThrowsError(try SpatialCalibration.decode(modified {
            var rooms = $0["rooms"] as! [[String: Any]]; rooms[0]["points"] = [["x": 0, "y": 0], ["x": 1, "y": 1], ["x": 1, "y": 0], ["x": 0, "y": 1]]; $0["rooms"] = rooms
        }))
        XCTAssertThrowsError(try SpatialCalibration.decode(modified {
            var rooms = $0["rooms"] as! [[String: Any]]; rooms[0]["name"] = " "; $0["rooms"] = rooms
        }))
    }
    func device(_ id: String, room: String = "home-living", home: String = "home") -> BoardDevice {
        BoardDevice(id: id, name: id, homeId: home, roomId: room, roomName: "客厅", reachable: true, services: [])
    }
    let homeRooms = [BoardRoom(id: "home-living", name: "客厅", isDefault: false, accessoryCount: 2)]
    func testImportBindsNamesPreservesDevicesAndOnlyPlacesMissingMembers() throws {
        let input = try SpatialCalibration.decode(sample)
        var old = FloorPlanLayout(homeID: "home"); old.devices["existing"] = PlanPoint(x: 0.2, y: 0.7)
        let next = try input.applying(to: old, homeRooms: homeRooms, devices: [device("existing"), device("new"), device("foreign", home: "other"), device("unmatched", room: "other")])
        XCTAssertNil(old.spatial) // Preparation does not mutate the original.
        XCTAssertEqual(next.spatial?.rooms.first?.id, "home-living")
        XCTAssertEqual(next.devices["existing"], old.devices["existing"])
        XCTAssertTrue(try XCTUnwrap(next.spatial?.rooms.first).contains(XCTUnwrap(next.devices["new"])))
        XCTAssertNil(next.devices["foreign"]); XCTAssertNil(next.devices["unmatched"])
        var noPlacement = input; noPlacement.placeDevices = false
        XCTAssertEqual(try noPlacement.applying(to: old, homeRooms: homeRooms, devices: [device("new")]).devices, old.devices)
    }
    func testDuplicateRoomBindingsAndAmbiguousHomeNamesAreRejected() throws {
        var input = try SpatialCalibration.decode(sample)
        var duplicate = input.rooms[0]; duplicate.id = "second-area"; input.rooms.append(duplicate)
        XCTAssertThrowsError(try input.applying(to: FloorPlanLayout(homeID: "home"), homeRooms: homeRooms, devices: []))
        input.rooms.removeLast()
        let duplicateHome = BoardRoom(id: "other-living", name: "客厅", isDefault: false, accessoryCount: 0)
        XCTAssertThrowsError(try input.applying(to: FloorPlanLayout(homeID: "home"), homeRooms: homeRooms + [duplicateHome], devices: []))
    }
    func testPromptIncludesContextCoordinatesAndValidExample() {
        let prompt = SpatialImportGuide.prompt(context: "{\"imageWidth\":1200,\"imageHeight\":800}")
        XCTAssertTrue(prompt.contains("\"imageWidth\":1200"))
        XCTAssertTrue(prompt.contains("depth=家具未旋转深度像素/图片高度"))
        XCTAssertTrue(prompt.contains(SpatialImportGuide.example))
    }
    func testUnmatchedNameCannotBindBySupplyingARealRoomID() throws {
        var input = try SpatialCalibration.decode(sample)
        input.rooms[0].name = "阳台"; input.rooms[0].id = "home-living"
        let next = try input.applying(to: FloorPlanLayout(homeID: "home"), homeRooms: homeRooms, devices: [device("lamp")])
        XCTAssertEqual(next.spatial?.rooms.first?.id, "import-local:home-living")
        XCTAssertTrue(next.devices.isEmpty)
    }

}
