import XCTest
@testable import HomeKitReadOnlyCore

final class ReadOnlyTests: XCTestCase {
    let fixture: [String: Any] = [
        "metadata": ["authorization": "authorized", "loaded": true, "readOnly": true],
        "homes": [["id": "h1", "name": "测试家庭",
                   "rooms": [["id": "r1", "name": "客厅", "homeId": "h1"], ["id": "r2", "name": "主卧", "homeId": "h1"]],
                   "accessories": [["id": "a1", "name": "同名灯", "roomId": "r1", "services": [["typeName": "switch"]]],
                                   ["id": "a2", "name": "同名灯", "roomId": "r2", "services": [["typeName": "outlet"]]]],
                   "scenes": [["id": "s1", "name": "睡觉", "actionCount": 2]]]]
    ]

    func request(_ method: String, _ params: [String: Any] = [:], inventory: (() throws -> [String: Any])? = nil) -> RPCReply {
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 9, "method": method, "params": params])
        return MCPRouter.handle(data, inventory: inventory ?? { self.fixture })
    }
    func payload(_ reply: RPCReply) -> [String: Any] {
        (reply.json?["result"] as? [String: Any])?["structuredContent"] as? [String: Any] ?? [:]
    }

    func testDiscoveryDoesNotTouchHomeKitAndExposesOnlyReadTools() {
        let response = request("tools/list", inventory: { XCTFail("Discovery must not request household data"); return [:] })
        let tools = (response.json?["result"] as? [String: Any])?["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.count, 6)
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), Set(["get_status", "list_homes", "list_rooms", "list_accessories", "get_accessory_capabilities", "list_scenes"]))
        XCTAssertTrue(tools.allSatisfy { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true })
    }
    func testMutationIsRejectedBeforeAccessingHomeKit() {
        let reply = request("tools/call", ["name": "set_accessory", "arguments": ["value": true]], inventory: { XCTFail(); return [:] })
        XCTAssertEqual((reply.json?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }
    func testPermissionDeniedIsNotReportedAsAnEmptyHome() {
        let reply = request("tools/call", ["name": "list_homes"], inventory: { ["metadata": ["authorization": "denied", "loaded": true]] })
        XCTAssertEqual(payload(reply)["code"] as? String, "authorization_required")
        XCTAssertEqual((reply.json?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }
    func testNotLoadedIsNotReportedAsSuccess() {
        let reply = request("tools/call", ["name": "list_homes"], inventory: { ["metadata": ["authorization": "authorized", "loaded": false]] })
        XCTAssertEqual(payload(reply)["code"] as? String, "homekit_loading")
    }
    func testExactRoomFilteringAndUnknownIDs() {
        let reply = request("tools/call", ["name": "list_accessories", "arguments": ["room_id": "r1"]])
        let accessories = payload(reply)["accessories"] as! [[String: Any]]
        XCTAssertEqual(accessories.count, 1)
        XCTAssertEqual(accessories[0]["id"] as? String, "a1")
        XCTAssertNil(accessories[0]["services"])
        let wrong = request("tools/call", ["name": "list_accessories", "arguments": ["room_id": "unknown"]])
        XCTAssertEqual(payload(wrong)["code"] as? String, "not_found")
    }
    func testCapabilitiesUseStableIDNotAmbiguousName() {
        let reply = request("tools/call", ["name": "get_accessory_capabilities", "arguments": ["accessory_id": "a2"]])
        let accessory = payload(reply)["accessory"] as! [String: Any]
        XCTAssertEqual((accessory["services"] as! [[String: Any]])[0]["typeName"] as? String, "outlet")
        let invalid = request("tools/call", ["name": "get_accessory_capabilities", "arguments": ["name": "同名灯"]])
        XCTAssertNotNil(invalid.json?["error"])
    }
    func testUnknownFilterNeverBroadensSelection() {
        let reply = request("tools/call", ["name": "list_accessories", "arguments": ["rom_id": "r1"]])
        XCTAssertNotNil(reply.json?["error"])
    }
    func testNotificationsReturn202AndDoNotReadData() {
        let data = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let reply = MCPRouter.handle(data, inventory: { XCTFail(); return [:] })
        XCTAssertEqual(reply.status, 202)
        XCTAssertNil(reply.json)
    }
    func testMalformedInputAndBooleanIDs() {
        XCTAssertEqual((MCPRouter.handle(Data("{".utf8), inventory: { [:] }).json?["error"] as? [String: Any])?["code"] as? Int, -32700)
        let reply = MCPRouter.handle(Data(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#.utf8), inventory: { [:] })
        XCTAssertEqual((reply.json?["error"] as? [String: Any])?["code"] as? Int, -32600)
    }
    func testNegotiatesProtocolAndPreservesID() {
        let reply = request("initialize", ["protocolVersion": "2025-06-18"])
        XCTAssertEqual(reply.json?["id"] as? Int, 9)
        XCTAssertEqual((reply.json?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
    }
}

final class HTTPTests: XCTestCase {
    let policy = HTTPPolicy(port: 18765, token: "test-secret")
    func wire(_ extra: String = "", host: String = "127.0.0.1:18765", token: String = "test-secret", method: String = "POST", body: String = "{}") -> Data {
        Data("\(method) /mcp HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8)
    }
    func testFragmentedRequestAndMultibyteBody() throws {
        let data = wire(body: "{\"name\":\"厨房\"}")
        XCTAssertNil(try HTTPParser.parse(data.prefix(data.count - 1)))
        let parsed = try XCTUnwrap(HTTPParser.parse(data))
        XCTAssertNoThrow(try policy.validate(parsed))
        XCTAssertEqual(String(data: parsed.body, encoding: .utf8), "{\"name\":\"厨房\"}")
    }
    func testRejectsBadTokenHostOriginAndProtocol() throws {
        for data in [wire(token: "wrong"), wire(host: "evil.example:18765"), wire("Origin: https://evil.example\r\n"), wire("MCP-Protocol-Version: unsupported\r\n")] {
            let request = try XCTUnwrap(HTTPParser.parse(data))
            XCTAssertThrowsError(try policy.validate(request))
        }
    }
    func testRejectsDuplicateLengthChunkingAndPipelining() {
        for data in [wire("Content-Length: 2\r\n"), wire("Transfer-Encoding: chunked\r\n"), wire() + wire()] {
            XCTAssertThrowsError(try HTTPParser.parse(data))
        }
    }
    func testBoundsHeadersAndBody() {
        XCTAssertThrowsError(try HTTPParser.parse(Data(repeating: 65, count: HTTPParser.maxHeaderBytes + 1)))
        XCTAssertThrowsError(try HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)))
    }
    func testNoSSESessionOrBrowserCorsEndpoint() throws {
        for method in ["GET", "DELETE", "OPTIONS"] {
            let request = try XCTUnwrap(HTTPParser.parse(wire(method: method)))
            XCTAssertThrowsError(try policy.validate(request))
        }
    }
}
