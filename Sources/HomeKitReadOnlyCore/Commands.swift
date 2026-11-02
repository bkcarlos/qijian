import Foundation
import CoreFoundation

public struct CommandFailure: Error, LocalizedError {
    public let code: String
    public let message: String
    public let details: [String: Any]
    public init(_ code: String, _ message: String, details: [String: Any] = [:]) {
        self.code = code; self.message = message; self.details = details
    }
    public var errorDescription: String? { message }
    public var payload: [String: Any] { ["code": code, "message": message, "details": details] }
}

public struct CommandDefinition {
    public let name: String
    public let description: String
    public let properties: [String: Any]
    public let required: [String]
    public let writes: Bool
    public var tool: [String: Any] {
        var fields = properties
        var needs = required
        if writes {
            fields["request_id"] = ["type": "string", "format": "uuid", "description": "Unique mutation key. Reuse only for the identical request in this app process. Poll get_operation; never blindly repeat an unknown outcome."]
            needs.append("request_id")
        }
        return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": fields, "required": needs, "additionalProperties": false],
                "annotations": ["readOnlyHint": !writes, "destructiveHint": writes, "idempotentHint": !writes, "openWorldHint": false]]
    }
}

public enum Commands {
    static let id: [String: Any] = ["type": "string", "minLength": 1]
    static let name: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 64]
    static let value: [String: Any] = ["type": ["boolean", "number", "string"], "description": "Exact scalar matching characteristic metadata. No coercion of strings or booleans to numbers."]
    static func def(_ name: String, _ description: String, _ fields: [String: Any], _ required: [String]? = nil, writes: Bool = true) -> CommandDefinition {
        CommandDefinition(name: name, description: description, properties: fields, required: required ?? Array(fields.keys).sorted(), writes: writes)
    }
    public static let definitions: [CommandDefinition] = [
        def("get_scene", "Get a scene's exact action IDs, characteristic IDs and target values. Does not execute it.", ["scene_id": id], writes: false),
        def("read_characteristic", "Actively read one readable scalar characteristic. Use an exact ID from capabilities. Binary camera/authentication data is not supported.", ["characteristic_id": id], writes: false),
        def("get_operation", "Get a mutation receipt by request_id. accepted/running is NOT success. outcome_unknown requires inspection; do not blindly retry.", ["request_id": id], writes: false),
        def("preview_change", "Validate a proposed mutation against current HomeKit metadata without submitting it. Does not guarantee later device acceptance.", ["tool": id, "arguments": ["type": "object"]], writes: false),
        def("create_home", "Create a HomeKit home. Returns an operation receipt; does not pair accessories.", ["name": name]),
        def("rename_home", "Rename an existing home using its exact ID.", ["home_id": id, "name": name]),
        def("create_room", "Create a room in the specified home. No accessories are moved automatically.", ["home_id": id, "name": name]),
        def("rename_room", "Rename a non-default room.", ["room_id": id, "name": name]),
        def("delete_room", "Delete an empty non-default room. Refuses occupied rooms; move their devices explicitly first.", ["room_id": id, "expected_name": name]),
        def("rename_accessory", "Rename an existing paired accessory.", ["accessory_id": id, "name": name]),
        def("move_accessory", "Move an accessory to an exact room ID in the same home. Does not re-pair devices.", ["accessory_id": id, "room_id": id]),
        def("rename_service", "Rename one accessory service using its exact ID.", ["service_id": id, "name": name]),
        def("set_service_display_type", "Set a Switch/Outlet associated display type: default, light or fan. Cannot convert a Switch to Outlet; that needs an upstream bridge change.", ["service_id": id, "display_type": ["type": "string", "enum": ["default", "light", "fan"]]]),
        def("write_characteristic", "Control one device characteristic with an explicitly typed value: power, temperature, brightness, mode, etc. Validate capabilities first; do not infer a target by name.", ["characteristic_id": id, "value": value]),
        def("create_scene", "Create a scene with optional characteristic actions in one home. Does not execute it. Multiple HomeKit writes are not atomic; partial failures report the created scene ID and completed actions.", ["home_id": id, "name": name, "actions": ["type": "array", "maxItems": 100, "items": ["type": "object", "properties": ["characteristic_id": id, "value": value], "required": ["characteristic_id", "value"], "additionalProperties": false]]], ["home_id", "name"]),
        def("rename_scene", "Rename a user-created scene. Built-in scenes cannot be renamed.", ["scene_id": id, "name": name]),
        def("upsert_scene_action", "Add a characteristic action, or update its target if already in the scene. Does not execute the scene.", ["scene_id": id, "characteristic_id": id, "value": value]),
        def("remove_scene_action", "Remove exactly one action from a scene by action ID. Does not operate the device.", ["scene_id": id, "action_id": id]),
        def("delete_scene", "Delete a user-created scene after exact name verification. Refuses scenes referenced by HomeKit triggers.", ["scene_id": id, "expected_name": name]),
        def("execute_scene", "Execute the specified non-empty scene. This changes real device states. Failures can be partial; inspect state before retrying.", ["scene_id": id])
    ]
    public static func definition(_ name: String) -> CommandDefinition? { definitions.first { $0.name == name } }

    /// Strict schema validation is also enforced server-side, never just advertised.
    public static func validateArguments(_ name: String, _ args: [String: Any], preview: Bool = false) throws {
        guard let def = definition(name) else { throw CommandFailure("unknown_tool", "Unknown command") }
        var allowed = Set(def.properties.keys)
        if def.writes { allowed.insert("request_id") }
        guard Set(args.keys).isSubset(of: allowed), def.required.allSatisfy({ args[$0] != nil }) else {
            throw CommandFailure("invalid_arguments", "Missing or unknown arguments for \(name)")
        }
        if def.writes, (!preview || args["request_id"] != nil), UUID(uuidString: args["request_id"] as? String ?? "") == nil {
            throw CommandFailure("invalid_arguments", "A UUID request_id is required for mutations")
        }
        for key in args.keys where key != "value" && key != "actions" && key != "arguments" {
            guard let text = args[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= ((key == "name" || key == "expected_name") ? 64 : 200),
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CommandFailure("invalid_arguments", "Invalid string for \(key)")
            }
        }
        if let actions = args["actions"] {
            guard let array = actions as? [[String: Any]], array.count <= 100 else { throw CommandFailure("invalid_arguments", "actions must contain at most 100 objects") }
            var ids = Set<String>()
            for action in array {
                guard Set(action.keys) == ["characteristic_id", "value"], let id = action["characteristic_id"] as? String, !id.isEmpty, ids.insert(id).inserted else {
                    throw CommandFailure("invalid_arguments", "Each action needs one unique characteristic_id and a value")
                }
            }
        }
        if name == "set_service_display_type", !["default", "light", "fan"].contains(args["display_type"] as? String ?? "") {
            throw CommandFailure("invalid_arguments", "display_type must be default, light or fan; Outlet conversion requires the upstream bridge")
        }
        if name == "preview_change", args["arguments"] as? [String: Any] == nil { throw CommandFailure("invalid_arguments", "arguments must be an object") }
    }

    public static func validateValue(_ value: Any, characteristic: [String: Any], forWrite: Bool = true) throws {
        if forWrite, characteristic["hardwareWritable"] as? Bool != true { throw CommandFailure("not_writable", "Characteristic is not writable") }
        let metadata = characteristic["metadata"] as? [String: Any] ?? [:]
        let format = metadata["format"] as? String ?? ""
        let number = value as? NSNumber
        let boolean = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch format {
        case "bool": guard boolean else { throw CommandFailure("invalid_value", "Expected a JSON boolean") }
        case "string":
            guard let string = value as? String, string.utf8.count <= (metadata["maxLength"] as? Int ?? 256) else { throw CommandFailure("invalid_value", "Expected a bounded string") }
        case "int", "uint8", "uint16", "uint32", "uint64", "float":
            guard let number, !boolean, number.doubleValue.isFinite else { throw CommandFailure("invalid_value", "Expected a finite JSON number") }
            let n = number.doubleValue
            if format != "float", n.rounded() != n { throw CommandFailure("invalid_value", "Expected an integer") }
            let typeBounds: [String: (Double, Double)] = ["int": (-2147483648, 2147483647), "uint8": (0, 255), "uint16": (0, 65535), "uint32": (0, 4294967295), "uint64": (0, 9007199254740991)]
            if let range = typeBounds[format], !(range.0...range.1).contains(n) { throw CommandFailure("invalid_value", "Number exceeds supported \(format) bounds") }
            if let min = metadata["minimum"] as? NSNumber, n < min.doubleValue { throw CommandFailure("invalid_value", "Value is below minimum") }
            if let max = metadata["maximum"] as? NSNumber, n > max.doubleValue { throw CommandFailure("invalid_value", "Value is above maximum") }
            if let valid = metadata["validValues"] as? [NSNumber], !valid.isEmpty, !valid.contains(where: { $0.doubleValue == n }) { throw CommandFailure("invalid_value", "Value is not in validValues") }
            if let step = metadata["step"] as? NSNumber, step.doubleValue > 0 {
                let base = (metadata["minimum"] as? NSNumber)?.doubleValue ?? 0
                let steps = (n - base) / step.doubleValue
                guard abs(steps - steps.rounded()) < max(0.00001, abs(steps) * 0.000001) else { throw CommandFailure("invalid_value", "Value does not match metadata step") }
            }
        default: throw CommandFailure("unsupported_format", "Binary, TLV and unknown characteristic formats are not supported")
        }
    }

    /// HomeKit commonly supplies NSNumber(0/1) even for bool metadata. Emit an
    /// actual JSON boolean so scene/read results can be used with strict writes.
    public static func normalizeScalar(_ value: Any, format: String) throws -> Any {
        switch format {
        case "bool":
            guard let number = value as? NSNumber, [0.0, 1.0].contains(number.doubleValue) else { throw CommandFailure("invalid_device_value", "HomeKit did not return a valid boolean") }
            return number.boolValue
        case "string":
            guard let text = value as? String else { throw CommandFailure("invalid_device_value", "HomeKit did not return a string") }
            return text
        case "int", "uint8", "uint16", "uint32", "uint64", "float":
            guard let number = value as? NSNumber, number.doubleValue.isFinite else { throw CommandFailure("invalid_device_value", "HomeKit did not return a finite number") }
            return number
        default: throw CommandFailure("unsupported_format", "Only scalar values are supported")
        }
    }
}

/// All targets are exact stable IDs. Validation happens before the first API mutation.
public struct HomeTopology {
    public let homes: [[String: Any]]
    public init(_ snapshot: [String: Any]) throws {
        let metadata = snapshot["metadata"] as? [String: Any] ?? [:]
        guard metadata["authorization"] as? String == "authorized" else { throw CommandFailure("authorization_required", "HomeKit access is not authorized") }
        guard metadata["loaded"] as? Bool == true else { throw CommandFailure("homekit_loading", "HomeKit topology has not loaded") }
        homes = snapshot["homes"] as? [[String: Any]] ?? []
    }
    public var accessories: [[String: Any]] { homes.flatMap { $0["accessories"] as? [[String: Any]] ?? [] } }
    public var rooms: [[String: Any]] { homes.flatMap { $0["rooms"] as? [[String: Any]] ?? [] } }
    public var scenes: [[String: Any]] { homes.flatMap { $0["scenes"] as? [[String: Any]] ?? [] } }
    public func one(_ items: [[String: Any]], _ id: String) throws -> [String: Any] {
        let found = items.filter { $0["id"] as? String == id }
        guard found.count == 1 else { throw CommandFailure("not_found", "Unknown or non-unique target ID") }
        return found[0]
    }
    public func service(_ id: String) throws -> [String: Any] { try one(accessories.flatMap { $0["services"] as? [[String: Any]] ?? [] }, id) }
    public func characteristic(_ id: String) throws -> (value: [String: Any], accessory: [String: Any]) {
        for a in accessories {
            let chars = (a["services"] as? [[String: Any]] ?? []).flatMap { $0["characteristics"] as? [[String: Any]] ?? [] }
            if let c = chars.first(where: { $0["id"] as? String == id }) { return (c, a) }
        }
        throw CommandFailure("not_found", "Unknown characteristic_id")
    }
    public func validate(_ name: String, _ args: [String: Any]) throws {
        func id(_ key: String) -> String { args[key] as? String ?? "" }
        if args["home_id"] != nil { _ = try one(homes, id("home_id")) }
        if args["accessory_id"] != nil { _ = try one(accessories, id("accessory_id")) }
        if args["service_id"] != nil { _ = try service(id("service_id")) }
        if args["room_id"] != nil {
            let room = try one(rooms, id("room_id"))
            if ["rename_room", "delete_room"].contains(name), room["isDefault"] as? Bool == true { throw CommandFailure("protected_room", "Default Room cannot be renamed or deleted") }
            if name == "delete_room" {
                guard room["name"] as? String == id("expected_name") else { throw CommandFailure("conflict", "Room name changed; re-read before deleting") }
                guard (room["accessoryCount"] as? Int ?? 0) == 0 else { throw CommandFailure("room_not_empty", "Move accessories explicitly before deleting this room") }
            }
            if name == "move_accessory" {
                let a = try one(accessories, id("accessory_id"))
                guard a["homeId"] as? String == room["homeId"] as? String else { throw CommandFailure("wrong_home", "Cannot move an accessory between homes") }
            }
        }
        var scene: [String: Any] = [:]
        if args["scene_id"] != nil {
            scene = try one(scenes, id("scene_id"))
            if ["rename_scene", "delete_scene"].contains(name), scene["userDefined"] as? Bool != true { throw CommandFailure("protected_scene", "Built-in scenes cannot be renamed or deleted") }
            if name == "delete_scene" {
                guard scene["name"] as? String == id("expected_name") else { throw CommandFailure("conflict", "Scene name changed; re-read before deleting") }
                guard (scene["triggerCount"] as? Int ?? 0) == 0 else { throw CommandFailure("scene_in_use", "This scene is referenced by HomeKit triggers") }
            }
            if name == "remove_scene_action" { _ = try one(scene["actions"] as? [[String: Any]] ?? [], id("action_id")) }
            if name == "execute_scene", (scene["actionCount"] as? Int ?? 0) == 0 { throw CommandFailure("empty_scene", "Scene has no actions") }
        }
        if args["characteristic_id"] != nil {
            let c = try characteristic(id("characteristic_id"))
            if name == "read_characteristic" {
                guard c.value["readable"] as? Bool == true else { throw CommandFailure("not_readable", "Characteristic is not readable") }
                let format = (c.value["metadata"] as? [String: Any])?["format"] as? String ?? ""
                guard ["bool", "int", "uint8", "uint16", "uint32", "uint64", "float", "string"].contains(format) else { throw CommandFailure("unsupported_format", "Only scalar characteristics can be read") }
            } else if let value = args["value"] { try Commands.validateValue(value, characteristic: c.value) }
            if name == "upsert_scene_action", c.accessory["homeId"] as? String != scene["homeId"] as? String { throw CommandFailure("wrong_home", "Scene and accessory must belong to the same home") }
        }
        if name == "set_service_display_type" {
            let s = try service(id("service_id"))
            guard ["switch", "outlet"].contains(s["typeName"] as? String ?? "") else { throw CommandFailure("unsupported_service", "Only Switch/Outlet supports associated display types") }
        }
        if name == "create_scene" {
            for action in args["actions"] as? [[String: Any]] ?? [] {
                let c = try characteristic(action["characteristic_id"] as? String ?? "")
                guard c.accessory["homeId"] as? String == id("home_id") else { throw CommandFailure("wrong_home", "All scene actions must belong to its home") }
                try Commands.validateValue(action["value"]!, characteristic: c.value)
            }
        }
        if ["create_room", "create_scene", "create_home"].contains(name) {
            let candidates = name == "create_home" ? homes : (name == "create_room" ? rooms : scenes).filter { $0["homeId"] as? String == id("home_id") }
            guard !candidates.contains(where: { ($0["name"] as? String)?.caseInsensitiveCompare(id("name")) == .orderedSame }) else { throw CommandFailure("name_exists", "An item with this name already exists") }
        }
    }
}
