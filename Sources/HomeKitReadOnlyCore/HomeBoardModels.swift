import Foundation

public enum ScalarValue: Codable, Equatable {
    case bool(Bool), number(Double), string(String)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .bool(let v): try c.encode(v); case .number(let v): try c.encode(v); case .string(let v): try c.encode(v) }
    }
    public var json: Any { switch self { case .bool(let v): return v; case .number(let v): return v; case .string(let v): return v } }
    public var text: String {
        switch self { case .bool(let v): return v ? "开启" : "关闭"; case .number(let v): return v.formatted(.number.precision(.fractionLength(0...2))); case .string(let v): return v }
    }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public static func from(_ raw: Any) throws -> ScalarValue {
        let data = try JSONSerialization.data(withJSONObject: [raw], options: [.fragmentsAllowed])
        return try JSONDecoder().decode([ScalarValue].self, from: data)[0]
    }
}
public struct BoardMetadata: Codable {
    public var format: String?
    public var units: String?
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    public var validValues: [Double]?
}
public struct BoardCharacteristic: Codable, Identifiable {
    public var id: String
    public var type: String
    public var description: String
    public var readable: Bool
    public var hardwareWritable: Bool
    public var metadata: BoardMetadata?
    public var shortType: String { String(type.prefix(8)) }
    public var editable: Bool { hardwareWritable && ["bool", "float", "int", "uint8", "uint16", "uint32", "uint64", "string"].contains(metadata?.format ?? "") }
    public var label: String {
        ["00000025": "电源", "000000B0": "运行", "00000008": "亮度", "00000013": "色相", "0000002F": "饱和度", "00000035": "目标温度", "00000011": "当前温度", "0000000D": "制冷温度", "00000012": "制热温度", "000000B2": "运行模式", "00000033": "目标模式", "00000029": "风速", "000000B6": "摆风", "00000010": "当前湿度", "00000034": "目标湿度", "00000036": "温度单位", "000000A7": "童锁"][shortType] ?? description
    }
    public func sensorText(_ value: ScalarValue?) -> String? {
        guard ["00000011", "00000010"].contains(shortType) else { return nil }
        guard let number = value?.number, number.isFinite else { return shortType == "00000011" ? "温度待刷新" : "湿度待刷新" }
        let text = number.formatted(.number.precision(.fractionLength(0...1)))
        if shortType == "00000010" { return "\(text)%" }
        return text + ((metadata?.units ?? "").lowercased().contains("fahrenheit") ? "℉" : "℃")
    }
    public var initialValue: ScalarValue {
        if metadata?.format == "bool" { return .bool(false) }
        if metadata?.format == "string" { return .string("") }
        return .number(metadata?.validValues?.first ?? metadata?.minimum ?? 0)
    }
}
public struct BoardService: Codable, Identifiable {
    public var id: String
    public var name: String
    public var typeName: String
    public var associatedServiceTypeName: String?
    public var primary: Bool
    public var userInteractive: Bool
    public var characteristics: [BoardCharacteristic]
}
public struct BoardDevice: Codable, Identifiable {
    public var id: String
    public var name: String
    public var homeId: String
    public var roomId: String
    public var roomName: String
    public var reachable: Bool
    public var services: [BoardService]
    public var controls: [BoardCharacteristic] { services.filter(\.userInteractive).flatMap(\.characteristics).filter(\.editable) }
    public var sensors: [BoardCharacteristic] {
        let readable = services.filter(\.userInteractive).flatMap(\.characteristics).filter(\.readable)
        return ["00000011", "00000010"].compactMap { type in readable.first { $0.shortType == type } }
    }
    public var power: BoardCharacteristic? {
        let sorted = services.filter(\.userInteractive).sorted { $0.primary && !$1.primary }
        for service in sorted {
            if let c = service.characteristics.first(where: { ["00000025", "000000B0"].contains($0.shortType) && $0.editable }) { return c }
        }
        return nil
    }
    /// Direct activation is reserved for a single readable power control.
    /// Count all writable characteristics, including unsupported formats, so a
    /// multi-function accessory never silently acts like a simple switch.
    public var supportsDirectPower: Bool {
        guard let power, power.readable,
              power.metadata?.format == "bool" || (power.shortType == "000000B0" && power.metadata?.format == "uint8") else { return false }
        let writable = services.filter(\.userInteractive).flatMap(\.characteristics).filter(\.hardwareWritable)
        return Set(writable.map(\.id)) == [power.id]
    }
    public var isLighting: Bool {
        services.contains { ($0.associatedServiceTypeName ?? $0.typeName) == "light" }
    }
    public var icon: String {
        let kinds = services.map { $0.associatedServiceTypeName ?? $0.typeName }
        if isLighting { return "lightbulb.fill" }
        if kinds.contains("outlet") || name.contains("插线板") { return "powerplug.fill" }
        if name.contains("摄像头") { return "video.fill" }
        if name.contains("电视") { return "tv.fill" }
        if kinds.contains("heater_cooler") || kinds.contains("thermostat") { return "air.conditioner.horizontal.fill" }
        if kinds.contains("air_purifier") { return "aqi.medium" }
        if kinds.contains("humidifier_dehumidifier") { return "humidity.fill" }
        if kinds.contains("fan") { return "fan.fill" }
        return "switch.2"
    }
}
public struct BoardRoom: Codable, Identifiable {
    public var id: String
    public var name: String
    public var isDefault: Bool
    public var accessoryCount: Int
}
public struct BoardSceneAction: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: String
    public var characteristicId: String?
    public var value: ScalarValue?
}
public struct BoardScene: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var homeId: String
    public var userDefined: Bool
    public var actionCount: Int
    public var actions: [BoardSceneAction]
}
public struct BoardHome: Codable, Identifiable {
    public var id: String
    public var name: String
    public var rooms: [BoardRoom]
    public var accessories: [BoardDevice]
    public var scenes: [BoardScene]
}
public struct SceneDraftAction: Identifiable, Equatable {
    public var id: String { characteristicId }
    public var characteristicId: String
    public var value: ScalarValue
    public init(characteristicId: String, value: ScalarValue) { self.characteristicId = characteristicId; self.value = value }
}
public struct BoardCommand {
    public var tool: String
    public var arguments: [String: Any]
}
public enum SceneEditPlanner {
    public static func plan(baseline: BoardScene?, current: BoardScene?, homeID: String, name: String, actions: [SceneDraftAction]) throws -> [BoardCommand] {
        guard Set(actions.map(\.characteristicId)).count == actions.count else { throw CommandFailure("duplicate_action", "同一特征不能重复添加") }
        guard let baseline else {
            return [BoardCommand(tool: "create_scene", arguments: ["home_id": homeID, "name": name, "actions": actions.map { ["characteristic_id": $0.characteristicId, "value": $0.value.json] }])]
        }
        guard let current, baseline.id == current.id, baseline.name == current.name,
              baseline.homeId == current.homeId, baseline.userDefined == current.userDefined,
              baseline.actions.sorted(by: { $0.id < $1.id }) == current.actions.sorted(by: { $0.id < $1.id }) else {
            throw CommandFailure("scene_changed", "场景已在其他位置修改，请重新打开编辑，避免覆盖最新设置。")
        }
        var commands: [BoardCommand] = []
        if name != baseline.name { commands.append(BoardCommand(tool: "rename_scene", arguments: ["scene_id": baseline.id, "name": name])) }
        for desired in actions {
            let previous = baseline.actions.filter { $0.characteristicId == desired.characteristicId }
            guard previous.count <= 1 else { throw CommandFailure("duplicate_action", "场景包含重复动作，请先整理。") }
            if previous.first?.value != desired.value { commands.append(BoardCommand(tool: "upsert_scene_action", arguments: ["scene_id": baseline.id, "characteristic_id": desired.characteristicId, "value": desired.value.json])) }
        }
        let ids = Set(actions.map(\.characteristicId))
        // Unsupported/binary actions remain untouched instead of being silently removed.
        for old in baseline.actions where old.kind == "characteristic_write" && old.value != nil && old.characteristicId != nil && !ids.contains(old.characteristicId!) {
            commands.append(BoardCommand(tool: "remove_scene_action", arguments: ["scene_id": baseline.id, "action_id": old.id]))
        }
        return commands
    }
}

public struct PlanPoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x.isFinite ? min(1, max(0, x)) : 0.5; self.y = y.isFinite ? min(1, max(0, y)) : 0.5 }
}
public struct FloorPlanLayout: Codable, Equatable {
    public var version = 1
    public var homeID: String
    public var devices: [String: PlanPoint] = [:]
    public var rooms: [String: PlanPoint] = [:]
    public var spatial: SpatialLayout?
    public init(homeID: String) { self.homeID = homeID }
    public static func decode(_ data: Data, homeID: String) throws -> FloorPlanLayout {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.homeID == homeID, result.version == 1,
              (Array(result.devices.values) + Array(result.rooms.values)).allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw CommandFailure("invalid_layout", "户型布局与当前家庭不匹配或坐标无效")
        }
        try result.spatial?.validate()
        return result
    }
}
