import Foundation
import HomeKit

extension HomeStore {
    static func describeAction(_ action: HMAction) -> [String: Any] {
        var result: [String: Any] = ["id": action.uniqueIdentifier.uuidString, "kind": "unsupported"]
        if let write = action as? HMCharacteristicWriteAction<NSCopying> {
            result["kind"] = "characteristic_write"
            result["characteristicId"] = write.characteristic.uniqueIdentifier.uuidString
            if let value = try? Commands.normalizeScalar(write.targetValue, format: write.characteristic.metadata?.format ?? "") { result["value"] = value }
            else { result["valueIncluded"] = false }
        }
        return result
    }

    private func findHome(_ id: String) throws -> HMHome {
        guard let home = manager?.homes.first(where: { $0.uniqueIdentifier.uuidString == id }) else { throw CommandFailure("not_found", "Home no longer exists") }
        return home
    }
    private func findAccessory(_ id: String) throws -> (HMHome, HMAccessory) {
        for home in manager?.homes ?? [] {
            if let item = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == id }) { return (home, item) }
        }
        throw CommandFailure("not_found", "Accessory no longer exists")
    }
    private func findRoom(_ id: String) throws -> (HMHome, HMRoom) {
        for home in manager?.homes ?? [] {
            if let item = (home.rooms + [home.roomForEntireHome()]).first(where: { $0.uniqueIdentifier.uuidString == id }) { return (home, item) }
        }
        throw CommandFailure("not_found", "Room no longer exists")
    }
    private func findService(_ id: String) throws -> HMService {
        for home in manager?.homes ?? [] {
            for accessory in home.accessories {
                if let item = accessory.services.first(where: { $0.uniqueIdentifier.uuidString == id }) { return item }
            }
        }
        throw CommandFailure("not_found", "Service no longer exists")
    }
    private func findCharacteristic(_ id: String) throws -> HMCharacteristic {
        for home in manager?.homes ?? [] {
            for accessory in home.accessories {
                for service in accessory.services {
                    if let item = service.characteristics.first(where: { $0.uniqueIdentifier.uuidString == id }) { return item }
                }
            }
        }
        throw CommandFailure("not_found", "Characteristic no longer exists")
    }
    private func findScene(_ id: String) throws -> (HMHome, HMActionSet) {
        for home in manager?.homes ?? [] {
            if let item = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == id }) { return (home, item) }
        }
        throw CommandFailure("not_found", "Scene no longer exists")
    }
    private func copyValue(_ value: Any) throws -> NSCopying {
        if let text = value as? String { return text as NSString }
        if let number = value as? NSNumber { return number }
        throw CommandFailure("invalid_value", "Only scalar values are supported")
    }

    func perform(_ name: String, arguments args: [String: Any]) async throws -> [String: Any] {
        #if targetEnvironment(simulator) && DEBUG
        if isDemo {
            if name == "read_characteristic", let id = args["characteristic_id"] as? String, let value = MobileDemo.values[id] { return ["value": value] }
            throw CommandFailure("demo_readonly", "演示模式不发送设备控制或保存家庭修改。请在真机上操作。")
        }
        #endif
        // Revalidate immediately before mutation; the accepted request may be stale.
        try Commands.validateArguments(name, args)
        try HomeTopology(snapshot()).validate(name, args)
        func id(_ key: String) -> String { args[key] as? String ?? "" }
        // Reads update characteristic caches, not the home topology. Publishing the
        // entire inventory per characteristic makes one batch look like many refreshes.
        defer { if name != "read_characteristic" { refreshPreview() } }
        switch name {
        case "create_home":
            guard let manager else { throw CommandFailure("homekit_loading", "HomeKit is not connected") }
            let home = try await manager.addHome(named: id("name"))
            return ["home_id": home.uniqueIdentifier.uuidString, "name": home.name]
        case "rename_home":
            let home = try findHome(id("home_id")); try await home.updateName(id("name"))
            return ["home_id": home.uniqueIdentifier.uuidString, "name": home.name]
        case "create_room":
            let home = try findHome(id("home_id")); let room = try await home.addRoom(named: id("name"))
            return ["room_id": room.uniqueIdentifier.uuidString, "home_id": home.uniqueIdentifier.uuidString, "name": room.name]
        case "rename_room":
            let (_, room) = try findRoom(id("room_id")); try await room.updateName(id("name"))
            return ["room_id": room.uniqueIdentifier.uuidString, "name": room.name]
        case "delete_room":
            let (home, room) = try findRoom(id("room_id")); try await home.removeRoom(room)
            return ["room_id": id("room_id"), "deleted": true]
        case "rename_accessory":
            let (_, accessory) = try findAccessory(id("accessory_id")); try await accessory.updateName(id("name"))
            return ["accessory_id": accessory.uniqueIdentifier.uuidString, "name": accessory.name]
        case "move_accessory":
            let (home, accessory) = try findAccessory(id("accessory_id")); let (roomHome, room) = try findRoom(id("room_id"))
            guard home.uniqueIdentifier == roomHome.uniqueIdentifier else { throw CommandFailure("wrong_home", "Accessory and room are not in the same home") }
            try await home.assignAccessory(accessory, to: room)
            return ["accessory_id": accessory.uniqueIdentifier.uuidString, "room_id": room.uniqueIdentifier.uuidString]
        case "rename_service":
            let service = try findService(id("service_id")); try await service.updateName(id("name"))
            return ["service_id": service.uniqueIdentifier.uuidString, "name": service.name]
        case "set_service_display_type":
            let service = try findService(id("service_id"))
            let types = ["light": HMServiceTypeLightbulb, "fan": HMServiceTypeFan]
            try await service.updateAssociatedServiceType(types[id("display_type")])
            return ["service_id": service.uniqueIdentifier.uuidString, "display_type": id("display_type")]
        case "read_characteristic":
            let characteristic = try findCharacteristic(id("characteristic_id")); try await characteristic.readValue()
            guard let rawValue = characteristic.value else { throw CommandFailure("value_unavailable", "HomeKit did not return a value") }
            let value = try Commands.normalizeScalar(rawValue, format: characteristic.metadata?.format ?? "")
            return ["characteristic_id": characteristic.uniqueIdentifier.uuidString, "value": value, "readAt": ISO8601DateFormatter().string(from: Date())]
        case "write_characteristic":
            let characteristic = try findCharacteristic(id("characteristic_id")); try await characteristic.writeValue(args["value"]!)
            return ["characteristic_id": characteristic.uniqueIdentifier.uuidString, "requestedValue": args["value"]!, "acknowledged": true, "verifiedByReadback": false]
        case "create_scene":
            let home = try findHome(id("home_id"))
            // Resolve and build every action before creating the scene, avoiding validation-driven partial writes.
            let actions = try (args["actions"] as? [[String: Any]] ?? []).map { action in
                HMCharacteristicWriteAction<NSCopying>(characteristic: try findCharacteristic(action["characteristic_id"] as! String), targetValue: try copyValue(action["value"]!))
            }
            let scene = try await home.addActionSet(named: id("name"))
            var completed: [String] = []
            do {
                for action in actions {
                    try await scene.addAction(action); completed.append(action.uniqueIdentifier.uuidString)
                }
            } catch {
                // No automatic rollback: deleting could destroy edits another client made meanwhile.
                throw CommandFailure("partial_failure", "Scene was created, but not all actions were added: \(error.localizedDescription)", details: ["scene_id": scene.uniqueIdentifier.uuidString, "completed_action_ids": completed, "requestedActionCount": actions.count])
            }
            return ["scene_id": scene.uniqueIdentifier.uuidString, "name": scene.name, "actionCount": scene.actions.count]
        case "rename_scene":
            let (_, scene) = try findScene(id("scene_id")); try await scene.updateName(id("name"))
            return ["scene_id": scene.uniqueIdentifier.uuidString, "name": scene.name]
        case "upsert_scene_action":
            let (_, scene) = try findScene(id("scene_id")); let characteristic = try findCharacteristic(id("characteristic_id"))
            let target = try copyValue(args["value"]!)
            let matches = scene.actions.compactMap { $0 as? HMCharacteristicWriteAction<NSCopying> }.filter { $0.characteristic.uniqueIdentifier == characteristic.uniqueIdentifier }
            guard matches.count <= 1 else { throw CommandFailure("conflict", "Multiple existing actions target this characteristic; remove duplicates explicitly") }
            let action: HMCharacteristicWriteAction<NSCopying>
            if let existing = matches.first { action = existing; try await action.updateTargetValue(target) }
            else { action = HMCharacteristicWriteAction(characteristic: characteristic, targetValue: target); try await scene.addAction(action) }
            return ["scene_id": scene.uniqueIdentifier.uuidString, "action": Self.describeAction(action)]
        case "remove_scene_action":
            let (_, scene) = try findScene(id("scene_id"))
            guard let action = scene.actions.first(where: { $0.uniqueIdentifier.uuidString == id("action_id") }) else { throw CommandFailure("not_found", "Action no longer exists in this scene") }
            try await scene.removeAction(action)
            return ["scene_id": scene.uniqueIdentifier.uuidString, "action_id": id("action_id"), "removed": true]
        case "delete_scene":
            let (home, scene) = try findScene(id("scene_id")); try await home.removeActionSet(scene)
            return ["scene_id": id("scene_id"), "deleted": true]
        case "execute_scene":
            let (home, scene) = try findScene(id("scene_id")); try await home.executeActionSet(scene)
            return ["scene_id": scene.uniqueIdentifier.uuidString, "acknowledged": true, "verifiedByReadback": false]
        default: throw CommandFailure("unknown_tool", "No native adapter for this tool")
        }
    }
}
