import XCTest
@testable import HomeKitReadOnlyCore

final class HomeBoardTests: XCTestCase {
    func scene(_ actions: [BoardSceneAction]) -> BoardScene {
        BoardScene(id: "scene", name: "Sleep", homeId: "home", userDefined: true, actionCount: actions.count, actions: actions)
    }
    func testLayoutRoundTripClampsAndKeepsHomesSeparate() throws {
        var layout = FloorPlanLayout(homeID: "home")
        layout.devices["lamp"] = PlanPoint(x: -0.1, y: 1.4)
        layout.rooms["room"] = PlanPoint(x: 0.3, y: 0.6)
        let data = try JSONEncoder().encode(layout)
        let decoded = try FloorPlanLayout.decode(data, homeID: "home")
        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(decoded.devices["lamp"], PlanPoint(x: 0, y: 1))
        XCTAssertThrowsError(try FloorPlanLayout.decode(data, homeID: "other"))
        XCTAssertThrowsError(try FloorPlanLayout.decode(Data(#"{"version":1,"homeID":"home","devices":{"a":{"x":4,"y":0}},"rooms":{}}"#.utf8), homeID: "home"))
    }
    func testScalarRoundTripPreservesBooleanAndNumberTypes() throws {
        let values: [ScalarValue] = [.bool(false), .number(0), .number(26.5), .string("value")]
        XCTAssertEqual(try JSONDecoder().decode([ScalarValue].self, from: JSONEncoder().encode(values)), values)
    }
    func testSceneEditPreservesUnsupportedActionsAndDiffsOnlyChanges() throws {
        let old = scene([BoardSceneAction(id: "old", kind: "characteristic_write", characteristicId: "lamp", value: .bool(true)), BoardSceneAction(id: "media", kind: "unsupported", characteristicId: nil, value: nil)])
        let plan = try SceneEditPlanner.plan(baseline: old, current: old, homeID: "home", name: "Sleep", actions: [SceneDraftAction(characteristicId: "lamp", value: .bool(false)), SceneDraftAction(characteristicId: "fan", value: .number(1))])
        XCTAssertEqual(plan.map(\.tool), ["upsert_scene_action", "upsert_scene_action"])
        let removal = try SceneEditPlanner.plan(baseline: old, current: old, homeID: "home", name: "Sleep", actions: [])
        XCTAssertEqual(removal.count, 1)
        XCTAssertEqual(removal[0].arguments["action_id"] as? String, "old")
    }
    func testSceneConflictRejectsBeforeAnyCommandButIgnoresActionOrder() throws {
        let actions = [BoardSceneAction(id: "a", kind: "characteristic_write", characteristicId: "lamp", value: .bool(false)), BoardSceneAction(id: "b", kind: "unsupported", characteristicId: nil, value: nil)]
        let old = scene(actions)
        var changed = old; changed.name = "Someone else's edit"
        XCTAssertThrowsError(try SceneEditPlanner.plan(baseline: old, current: changed, homeID: "home", name: "New", actions: []))
        XCTAssertThrowsError(try SceneEditPlanner.plan(baseline: old, current: nil, homeID: "home", name: "New", actions: []))
        let same = scene(actions.reversed())
        XCTAssertEqual(try SceneEditPlanner.plan(baseline: old, current: same, homeID: "home", name: "Sleep", actions: [SceneDraftAction(characteristicId: "lamp", value: .bool(false))]).count, 0)
    }
    func testNewScenePlanNeverExecutesSceneOrWritesDevices() throws {
        let desired = [SceneDraftAction(characteristicId: "lamp", value: .bool(false))]
        let commands = try SceneEditPlanner.plan(baseline: nil, current: nil, homeID: "home", name: "New", actions: desired)
        XCTAssertEqual(commands.map(\.tool), ["create_scene"])
        XCTAssertThrowsError(try SceneEditPlanner.plan(baseline: nil, current: nil, homeID: "home", name: "New", actions: desired + desired))
    }
    func directDevice(_ characteristics: [BoardCharacteristic]) -> BoardDevice {
        BoardDevice(id: "device", name: "Lamp", homeId: "home", roomId: "room", roomName: "Room", reachable: true,
                    services: [BoardService(id: "service", name: "Lamp", typeName: "light", primary: true, userInteractive: true, characteristics: characteristics)])
    }
    func control(_ id: String, type: String = "00000025", format: String = "bool", writable: Bool = true, readable: Bool = true) -> BoardCharacteristic {
        BoardCharacteristic(id: id, type: type, description: id, readable: readable, hardwareWritable: writable,
                            metadata: BoardMetadata(format: format))
    }
    func testDirectPowerAllowsSingleSwitchWithReadOnlyTelemetry() {
        let power = control("power")
        XCTAssertTrue(directDevice([power]).supportsDirectPower)
        XCTAssertTrue(directDevice([power, control("usage", type: "vendor", format: "float", writable: false)]).supportsDirectPower)
        XCTAssertTrue(directDevice([control("active", type: "000000B0", format: "uint8")]).supportsDirectPower)
        XCTAssertFalse(directDevice([control("unreadable", readable: false)]).supportsDirectPower)
        XCTAssertFalse(directDevice([control("textPower", format: "string")]).supportsDirectPower)
    }
    func testDirectPowerRejectsMultiControlAndUnsupportedWritableControls() {
        let power = control("power")
        XCTAssertFalse(directDevice([power, control("brightness", type: "00000008", format: "int")]).supportsDirectPower)
        XCTAssertFalse(directDevice([power, control("vendor", type: "vendor", format: "tlv8")]).supportsDirectPower)
        XCTAssertFalse(directDevice([control("brightness", type: "00000008", format: "int")]).supportsDirectPower)
        XCTAssertFalse(directDevice([]).supportsDirectPower)
        var strip = directDevice([power])
        strip.services.append(BoardService(id: "second", name: "Outlet 2", typeName: "outlet", primary: false, userInteractive: true, characteristics: [control("secondPower")]))
        XCTAssertFalse(strip.supportsDirectPower)
    }

    func testSensorSummaryUsesCurrentReadingsAndPreservesUnits() {
        var temperature = control("temperature", type: "00000011", format: "float", writable: false)
        let humidity = control("humidity", type: "00000010", format: "float", writable: false)
        let target = control("target", type: "00000035", format: "float")
        let device = directDevice([control("power"), temperature, humidity, target])
        XCTAssertEqual(device.sensors.map(\.id), ["temperature", "humidity"])
        XCTAssertEqual(temperature.sensorText(.number(26.5)), "26.5℃")
        XCTAssertEqual(humidity.sensorText(.number(48)), "48%")
        XCTAssertEqual(temperature.sensorText(nil), "温度待刷新")
        XCTAssertEqual(humidity.sensorText(.number(.nan)), "湿度待刷新")
        XCTAssertNil(target.sensorText(.number(22)))
        temperature.metadata?.units = "fahrenheit"
        XCTAssertEqual(temperature.sensorText(.number(72)), "72℉")
    }

}
