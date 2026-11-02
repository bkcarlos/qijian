import XCTest
@testable import HomeKitReadOnlyCore

final class ControlTests: XCTestCase {
    var fixture: [String: Any] {
        ["metadata": ["authorization": "authorized", "loaded": true], "homes": [
            ["id": "h1", "name": "Home", "rooms": [
                ["id": "r0", "name": "Default Room", "homeId": "h1", "isDefault": true, "accessoryCount": 0],
                ["id": "r1", "name": "Living", "homeId": "h1", "isDefault": false, "accessoryCount": 1],
                ["id": "r2", "name": "Empty", "homeId": "h1", "isDefault": false, "accessoryCount": 0]],
             "accessories": [["id": "a1", "name": "Lamp", "homeId": "h1", "services": [
                ["id": "s1", "typeName": "switch", "characteristics": [
                    ["id": "c1", "readable": true, "hardwareWritable": true, "metadata": ["format": "bool"]],
                    ["id": "c2", "readable": true, "hardwareWritable": true, "metadata": ["format": "float", "minimum": 16, "maximum": 30, "step": 0.10000000149]],
                    ["id": "c3", "readable": true, "hardwareWritable": true, "metadata": ["format": "uint8", "validValues": [0, 2]]],
                    ["id": "c4", "readable": true, "hardwareWritable": false, "metadata": ["format": "float"]],
                    ["id": "c5", "readable": true, "hardwareWritable": true, "metadata": ["format": "tlv8"]]]]]]],
             "scenes": [["id": "sc1", "name": "Sleep", "homeId": "h1", "userDefined": true, "triggerCount": 0, "actionCount": 1, "actions": [["id": "act1", "characteristicId": "c1", "value": false]]],
                        ["id": "sc2", "name": "Built in", "homeId": "h1", "userDefined": false, "actionCount": 0],
                        ["id": "sc3", "name": "In use", "homeId": "h1", "userDefined": true, "triggerCount": 1, "actionCount": 1]]],
            ["id": "h2", "name": "Other", "rooms": [["id": "r3", "name": "Other room", "homeId": "h2"]], "scenes": [["id": "sc4", "name": "Other scene", "homeId": "h2"]]]
        ]]
    }
    func payload(_ reply: RPCReply) -> [String: Any] { (reply.json?["result"] as? [String: Any])?["structuredContent"] as? [String: Any] ?? [:] }
    func wire(_ name: String, _ args: [String: Any], id: Any? = 1) -> Data {
        var request: [String: Any] = ["jsonrpc": "2.0", "method": "tools/call", "params": ["name": name, "arguments": args]]
        request["id"] = id
        return try! JSONSerialization.data(withJSONObject: request)
    }
    func testScalarTypesRangesAndStepAreStrict() throws {
        let t = try HomeTopology(fixture)
        for (id, value) in [("c1", "false" as Any), ("c1", 0), ("c2", true), ("c2", 31), ("c2", 16.05), ("c3", 1), ("c3", 2.5), ("c4", 19), ("c5", "AQ==")] {
            XCTAssertThrowsError(try t.validate("write_characteristic", ["characteristic_id": id, "value": value]), "\(id): \(value)")
        }
        XCTAssertNoThrow(try t.validate("write_characteristic", ["characteristic_id": "c1", "value": false]))
        XCTAssertNoThrow(try t.validate("write_characteristic", ["characteristic_id": "c2", "value": 26.3]))
        XCTAssertNoThrow(try t.validate("write_characteristic", ["characteristic_id": "c3", "value": 2]))
    }
    func testHomeKitNumericBooleansBecomeJSONBooleans() throws {
        let value = try Commands.normalizeScalar(NSNumber(value: 0), format: "bool")
        let data = try JSONSerialization.data(withJSONObject: ["value": value])
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"value\":false}")
        XCTAssertThrowsError(try Commands.normalizeScalar("false", format: "bool"))
        XCTAssertThrowsError(try Commands.normalizeScalar(NSNumber(value: Double.nan), format: "float"))
        XCTAssertThrowsError(try Commands.normalizeScalar(Data(), format: "tlv8"))
    }
    func testCrossHomeAndProtectedTargetsRejected() throws {
        let t = try HomeTopology(fixture)
        for (tool, args): (String, [String: Any]) in [
            ("move_accessory", ["accessory_id": "a1", "room_id": "r3"]),
            ("upsert_scene_action", ["scene_id": "sc4", "characteristic_id": "c1", "value": false]),
            ("rename_room", ["room_id": "r0", "name": "New"]),
            ("delete_room", ["room_id": "r1", "expected_name": "Living"]),
            ("delete_room", ["room_id": "r2", "expected_name": "Stale"]),
            ("rename_scene", ["scene_id": "sc2", "name": "New"]),
            ("delete_scene", ["scene_id": "sc3", "expected_name": "In use"]),
            ("execute_scene", ["scene_id": "sc2"]),
            ("remove_scene_action", ["scene_id": "sc1", "action_id": "wrong"]),
            ("create_room", ["home_id": "h1", "name": "living"])
        ] { XCTAssertThrowsError(try t.validate(tool, args), tool) }
    }
    func testScenePreflightChecksEveryActionAndRejectsDuplicates() throws {
        let args: [String: Any] = ["home_id": "h1", "name": "New", "actions": [["characteristic_id": "c1", "value": false], ["characteristic_id": "c2", "value": 999]]]
        XCTAssertThrowsError(try HomeTopology(fixture).validate("create_scene", args))
        XCTAssertThrowsError(try Commands.validateArguments("create_scene", ["home_id": "h1", "name": "New", "actions": [["characteristic_id": "c1", "value": false], ["characteristic_id": "c1", "value": true]]], preview: true))
    }
    func testInvalidArgumentsAndUnsupportedDisplayTypes() {
        for args: [String: Any] in [["service_id": "s1", "display_type": "outlet"], ["service_id": "s1", "display_type": "light", "typo": true]] {
            XCTAssertThrowsError(try Commands.validateArguments("set_service_display_type", args, preview: true))
        }
        XCTAssertThrowsError(try Commands.validateArguments("create_room", ["home_id": "h1", "name": " ", "request_id": UUID().uuidString]))
        XCTAssertThrowsError(try Commands.validateArguments("create_room", ["home_id": "h1", "name": "New", "request_id": "not-a-uuid"]))
    }
    @MainActor func testScopeAndLocalSwitchRejectBeforeBackend() async {
        let r = ControlRouter(); var called = 0
        let data = wire("write_characteristic", ["characteristic_id": "c1", "value": false, "request_id": UUID().uuidString])
        let perform: @MainActor (String, [String: Any]) async throws -> [String: Any] = { _, _ in called += 1; return [:] }
        r.writesEnabled = true
        let read = await r.handle(data, role: .read, inventory: { XCTFail("Read credential must fail before inventory"); return [:] }, perform: perform)
        XCTAssertEqual(payload(read)["code"] as? String, "read_only_credential")
        r.writesEnabled = false
        let disabled = await r.handle(data, role: .control, inventory: { XCTFail(); return [:] }, perform: perform)
        XCTAssertEqual(payload(disabled)["code"] as? String, "writes_disabled")
        XCTAssertEqual(called, 0)
    }
    @MainActor func testPreviewUsesLiveMetadataButNeverPerforms() async {
        let router = ControlRouter()
        let response = await router.handle(wire("preview_change", ["tool": "write_characteristic", "arguments": ["characteristic_id": "c1", "value": false]]), role: .read, inventory: { self.fixture }, perform: { _, _ in XCTFail(); return [:] })
        XCTAssertEqual(payload(response)["valid"] as? Bool, true)
        XCTAssertEqual(payload(response)["submitted"] as? Bool, false)
        XCTAssertFalse(router.operations.busy)
    }
    @MainActor func testNotificationsAndBadIDsNeverMutate() async {
        let router = ControlRouter(); router.writesEnabled = true
        let args: [String: Any] = ["characteristic_id": "c1", "value": true, "request_id": UUID().uuidString]
        for id: Any? in [nil, true] {
            let reply = await router.handle(wire("write_characteristic", args, id: id), role: .control, inventory: { XCTFail(); return [:] }, perform: { _, _ in XCTFail(); return [:] })
            if id == nil { XCTAssertEqual(reply.status, 202) } else { XCTAssertNotNil(reply.json?["error"]) }
        }
    }
    @MainActor func testDuplicateIDDoesNotExecuteTwiceAndChangedPayloadConflicts() async throws {
        let router = ControlRouter(); router.writesEnabled = true
        var calls = 0
        let key = UUID().uuidString
        let args: [String: Any] = ["characteristic_id": "c1", "value": false, "request_id": key]
        let perform: @MainActor (String, [String: Any]) async throws -> [String: Any] = { _, _ in calls += 1; return ["ok": true] }
        for _ in 0..<2 { _ = await router.handle(wire("write_characteristic", args), role: .control, inventory: { self.fixture }, perform: perform) }
        for _ in 0..<100 where router.operations.busy { await Task.yield() }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try router.operations.get(key)["state"] as? String, "succeeded")
        var different = args; different["value"] = true
        let conflict = await router.handle(wire("write_characteristic", different), role: .control, inventory: { self.fixture }, perform: perform)
        XCTAssertEqual(payload(conflict)["code"] as? String, "request_id_conflict")
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testTimeoutReportsUnknownAndDoesNotUnlockInFlightMutation() async throws {
        let center = OperationCenter(timeoutNanoseconds: 1_000_000)
        var continuation: CheckedContinuation<[String: Any], Error>?
        let key = UUID().uuidString
        _ = try center.submit(key, tool: "test", fingerprint: Data()) { try await withCheckedThrowingContinuation { continuation = $0 } }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(try center.get(key)["state"] as? String, "outcome_unknown")
        XCTAssertTrue(center.busy)
        XCTAssertThrowsError(try center.submit(UUID().uuidString, tool: "test", fingerprint: Data()) { [:] })
        continuation?.resume(returning: ["done": true])
        for _ in 0..<100 where center.busy { await Task.yield() }
        XCTAssertFalse(center.busy)
        XCTAssertEqual(try center.get(key)["state"] as? String, "succeeded")
    }
    @MainActor func testPartialFailureKeepsRecoveryDetails() async throws {
        let center = OperationCenter(); let key = UUID().uuidString
        _ = try center.submit(key, tool: "create_scene", fingerprint: Data()) { throw CommandFailure("partial_failure", "Failed after create", details: ["scene_id": "created-scene"]) }
        for _ in 0..<100 where center.busy { await Task.yield() }
        let result = try center.get(key)
        XCTAssertEqual(result["state"] as? String, "partial_failure")
        XCTAssertEqual(((result["error"] as? [String: Any])?["details"] as? [String: Any])?["scene_id"] as? String, "created-scene")
    }
    @MainActor func testDiscoverySeparatesReadAndControlTools() async throws {
        let router = ControlRouter()
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        for role in [AccessRole.read, .control] {
            let response = await router.handle(data, role: role, inventory: { XCTFail(); return [:] }, perform: { _, _ in XCTFail(); return [:] })
            let tools = (response.json?["result"] as! [String: Any])["tools"] as! [[String: Any]]
            XCTAssertEqual(tools.count, role == .read ? 10 : 26)
            if role == .read { XCTAssertTrue(tools.allSatisfy { ($0["annotations"] as! [String: Any])["readOnlyHint"] as? Bool == true }) }
        }
    }
    func testTransportCredentialScopes() throws {
        let policy = HTTPPolicy(port: 18765, token: "read", controlToken: "control")
        for (token, role) in [("read", AccessRole.read), ("control", .control)] {
            let request = HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:18765", "authorization": "Bearer " + token, "content-type": "application/json", "accept": "application/json, text/event-stream"], body: Data())
            XCTAssertEqual(try policy.authorize(request), role)
        }
    }

    @MainActor func testEveryMutationRoutesToBackendAfterValidation() async throws {
        let router = ControlRouter(); router.writesEnabled = true
        let cases: [(String, [String: Any])] = [
            ("create_home", ["name": "New home"]),
            ("rename_home", ["home_id": "h1", "name": "Renamed"]),
            ("create_room", ["home_id": "h1", "name": "New room"]),
            ("rename_room", ["room_id": "r2", "name": "Renamed"]),
            ("delete_room", ["room_id": "r2", "expected_name": "Empty"]),
            ("rename_accessory", ["accessory_id": "a1", "name": "Renamed"]),
            ("move_accessory", ["accessory_id": "a1", "room_id": "r2"]),
            ("rename_service", ["service_id": "s1", "name": "Renamed"]),
            ("set_service_display_type", ["service_id": "s1", "display_type": "light"]),
            ("write_characteristic", ["characteristic_id": "c1", "value": false]),
            ("create_scene", ["home_id": "h1", "name": "New scene", "actions": [["characteristic_id": "c1", "value": false]]]),
            ("rename_scene", ["scene_id": "sc1", "name": "Renamed"]),
            ("upsert_scene_action", ["scene_id": "sc1", "characteristic_id": "c1", "value": true]),
            ("remove_scene_action", ["scene_id": "sc1", "action_id": "act1"]),
            ("delete_scene", ["scene_id": "sc1", "expected_name": "Sleep"]),
            ("execute_scene", ["scene_id": "sc1"])
        ]
        XCTAssertEqual(Set(cases.map { $0.0 }), Set(Commands.definitions.filter(\.writes).map(\.name)))
        var calls: [String] = []
        for (name, arguments) in cases {
            var args = arguments; let key = UUID().uuidString; args["request_id"] = key
            let reply = await router.handle(wire(name, args), role: .control, inventory: { self.fixture }, perform: { calledName, received in
                calls.append(calledName)
                XCTAssertEqual(received["request_id"] as? String, key)
                return ["simulated": true]
            })
            XCTAssertEqual(payload(reply)["request_id"] as? String, key, name)
            for _ in 0..<100 where router.operations.busy { await Task.yield() }
            XCTAssertEqual(try router.operations.get(key)["state"] as? String, "succeeded", name)
        }
        XCTAssertEqual(calls, cases.map { $0.0 })
    }

    @MainActor func testInvalidWriteAndPermissionDeniedNeverReachBackend() async {
        let router = ControlRouter(); router.writesEnabled = true
        let data = wire("write_characteristic", ["characteristic_id": "c2", "value": 99, "request_id": UUID().uuidString])
        let badValue = await router.handle(data, role: .control, inventory: { self.fixture }, perform: { _, _ in XCTFail(); return [:] })
        XCTAssertEqual(payload(badValue)["code"] as? String, "invalid_value")
        let denied = await router.handle(data, role: .control, inventory: { ["metadata": ["authorization": "denied", "loaded": true]] }, perform: { _, _ in XCTFail(); return [:] })
        XCTAssertEqual(payload(denied)["code"] as? String, "authorization_required")
    }
}
