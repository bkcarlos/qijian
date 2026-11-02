import SwiftUI
import HomeKit

struct AccessoryRow: Identifiable {
    let id: String
    let home: String
    let room: String
    let name: String
    let serviceSummary: String
    let reachable: Bool
}

@MainActor
final class HomeStore: NSObject, ObservableObject, HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate {
    @Published var authorization = "not_requested"
    @Published var loaded = false
    @Published var rows: [AccessoryRow] = []
    @Published var summary = "尚未连接 HomeKit"
    @Published var lastUpdated = ""
    private(set) var manager: HMHomeManager?
    private var topologyRefresh: Task<Void, Never>?

    #if targetEnvironment(simulator) && DEBUG
    var isDemo: Bool { !ProcessInfo.processInfo.arguments.contains("--live-homekit") }
    #endif

    func connect() {
        #if targetEnvironment(simulator) && DEBUG
        if isDemo { loaded = true; refreshPreview(); return }
        #endif
        guard manager == nil else { refreshPreview(); return }
        summary = "等待系统授权和家庭数据…"
        manager = HMHomeManager()
        manager?.delegate = self
        refreshPreview()
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.loaded = true; self.refreshPreview() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in self.refreshPreview() }
    }

    // Phone pairing emits several topology changes (add, name, room, services).
    // Coalesce them without subscribing to characteristic values or reading devices.
    private nonisolated func scheduleTopologyRefresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.topologyRefresh?.cancel()
            self.topologyRefresh = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                guard let self else { return }
                self.topologyRefresh = nil
                self.refreshPreview()
            }
        }
    }

    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) { scheduleTopologyRefresh() }
    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) { scheduleTopologyRefresh() }
    nonisolated func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) { scheduleTopologyRefresh() }
    nonisolated func home(_ home: HMHome, didAdd room: HMRoom) { scheduleTopologyRefresh() }
    nonisolated func home(_ home: HMHome, didRemove room: HMRoom) { scheduleTopologyRefresh() }
    nonisolated func home(_ home: HMHome, didUpdateNameFor room: HMRoom) { scheduleTopologyRefresh() }
    nonisolated func homeDidUpdateName(_ home: HMHome) { scheduleTopologyRefresh() }
    nonisolated func accessoryDidUpdateName(_ accessory: HMAccessory) { scheduleTopologyRefresh() }
    nonisolated func accessoryDidUpdateServices(_ accessory: HMAccessory) { scheduleTopologyRefresh() }

    func refreshPreview() {
        #if targetEnvironment(simulator) && DEBUG
        if isDemo { authorization = "authorized"; summary = "演示家庭 · 3 个房间 · 4 个设备"; lastUpdated = UUID().uuidString; return }
        #endif
        authorization = authorizationName
        let homes = manager?.homes ?? []
        for home in homes {
            home.delegate = self
            for accessory in home.accessories { accessory.delegate = self }
        }
        rows = homes.flatMap { home in
            home.accessories.map { accessory in
                AccessoryRow(id: accessory.uniqueIdentifier.uuidString, home: home.name,
                             room: accessory.room?.name ?? "未分配", name: accessory.name,
                             serviceSummary: accessory.services.filter(\.isUserInteractive).map { Self.serviceName($0.serviceType) }.joined(separator: "、"),
                             reachable: accessory.isReachable)
            }
        }.sorted { ($0.home, $0.room, $0.name) < ($1.home, $1.room, $1.name) }
        if authorization == "authorized" && loaded {
            summary = "\(homes.count) 个家庭 · \(homes.reduce(0) { $0 + $1.rooms.count }) 个房间 · \(rows.count) 个配件"
        } else if authorization == "denied" || authorization == "restricted" {
            summary = "家庭访问未获授权。请在系统设置的隐私与安全性中检查家庭权限。"
        }
        lastUpdated = ISO8601DateFormatter().string(from: Date())
    }

    private var authorizationName: String {
        guard let manager else { return "not_requested" }
        let s = manager.authorizationStatus
        if s.contains(.authorized) { return "authorized" }
        if s.contains(.restricted) { return "restricted" }
        if s.contains(.determined) { return "denied" }
        return "pending"
    }

    /// Enumerates HomeKit's in-memory topology. No characteristic values are read,
    /// subscriptions created, identify commands sent, or configuration modified.
    func snapshot() -> [String: Any] {
        #if targetEnvironment(simulator) && DEBUG
        if isDemo { return MobileDemo.snapshot }
        #endif
        let auth = authorizationName
        var metadata: [String: Any] = [
            "source": "Apple HomeKit HMHomeManager", "readOnly": true, "serverWriteEnabled": false,
            "authorization": auth, "loaded": loaded && auth == "authorized",
            "enumeratedAt": ISO8601DateFormatter().string(from: Date()),
            "reachabilitySource": "HomeKit cached state; not an active device probe",
            "characteristicValuesIncluded": false,
            "limitations": ["Apple Home UI may contain devices or settings not exposed by HomeKit.",
                            "Hardware writable flags do not guarantee operation success; writes also require a control credential and the local write switch.",
                            "Switch-to-outlet conversion must be done by the accessory/HA bridge, not associatedServiceType."]
        ]
        guard let manager, auth == "authorized", loaded else { return ["metadata": metadata, "homes": []] }
        let homes: [[String: Any]] = manager.homes.map { home in
            let homeID = home.uniqueIdentifier.uuidString
            // Include the default/entire-home room if HomeKit returns it only via an accessory.
            var roomMap = Dictionary(uniqueKeysWithValues: home.rooms.map { ($0.uniqueIdentifier, $0) })
            for accessory in home.accessories { if let room = accessory.room { roomMap[room.uniqueIdentifier] = room } }
            let rooms: [[String: Any]] = roomMap.values.sorted { $0.name < $1.name }.map {
                ["id": $0.uniqueIdentifier.uuidString, "name": $0.name, "homeId": homeID,
                 "accessoryCount": $0.accessories.count, "isDefault": $0.uniqueIdentifier == home.roomForEntireHome().uniqueIdentifier]
            }
            let accessories: [[String: Any]] = home.accessories.sorted { $0.name < $1.name }.map { accessory in
                var item: [String: Any] = [
                    "id": accessory.uniqueIdentifier.uuidString, "name": accessory.name,
                    "homeId": homeID, "roomId": accessory.room?.uniqueIdentifier.uuidString ?? "",
                    "roomName": accessory.room?.name ?? "", "reachable": accessory.isReachable,
                    "bridged": accessory.isBridged, "category": accessory.category.categoryType,
                    "categoryDescription": accessory.category.localizedDescription,
                    "serviceTypes": accessory.services.map { Self.serviceName($0.serviceType) },
                    "services": accessory.services.map(Self.describeService)
                ]
                item["bridgedAccessoryIds"] = accessory.bridgedAccessories.map { $0.uniqueIdentifier.uuidString }
                return item
            }
            let scenes: [[String: Any]] = home.actionSets.map { scene in
                ["id": scene.uniqueIdentifier.uuidString, "name": scene.name, "homeId": homeID,
                 "actionCount": scene.actions.count, "userDefined": scene.actionSetType == HMActionSetTypeUserDefined,
                 "triggerCount": home.triggers.filter { $0.actionSets.contains(scene) }.count,
                 "actions": scene.actions.map(Self.describeAction)]
            }
            return ["id": homeID, "name": home.name, "rooms": rooms, "accessories": accessories, "scenes": scenes]
        }
        metadata["homeCount"] = homes.count
        metadata["accessoryCount"] = manager.homes.reduce(0) { $0 + $1.accessories.count }
        return ["metadata": metadata, "homes": homes]
    }

    private static func describeService(_ service: HMService) -> [String: Any] {
        var result: [String: Any] = [
            "id": service.uniqueIdentifier.uuidString, "name": service.name,
            "type": service.serviceType, "typeName": serviceName(service.serviceType),
            "description": service.localizedDescription,
            "primary": service.isPrimaryService, "userInteractive": service.isUserInteractive,
            "characteristics": service.characteristics.map { c -> [String: Any] in
                var value: [String: Any] = [
                    "id": c.uniqueIdentifier.uuidString, "type": c.characteristicType,
                    "description": c.localizedDescription, "properties": c.properties,
                    "readable": c.properties.contains(HMCharacteristicPropertyReadable),
                    "hardwareWritable": c.properties.contains(HMCharacteristicPropertyWritable),
                    "supportsNotifications": c.properties.contains(HMCharacteristicPropertySupportsEventNotification)
                ]
                if let m = c.metadata {
                    var metadata: [String: Any] = [:]
                    metadata["format"] = m.format
                    metadata["units"] = m.units
                    metadata["minimum"] = m.minimumValue
                    metadata["maximum"] = m.maximumValue
                    metadata["step"] = m.stepValue
                    metadata["validValues"] = m.validValues
                    metadata["maxLength"] = m.maxLength
                    value["metadata"] = metadata
                }
                return value
            }
        ]
        result["associatedServiceType"] = service.associatedServiceType
        if let type = service.associatedServiceType { result["associatedServiceTypeName"] = serviceName(type) }
        if service.serviceType == HMServiceTypeSwitch {
            result["displayNote"] = "Exposed as Switch. Apple Home commonly offers switch/light/fan. Outlet requires the bridge to expose an Outlet service. This server cannot change it."
        }
        return result
    }

    static func serviceName(_ type: String) -> String {
        let names = [HMServiceTypeSwitch: "switch", HMServiceTypeOutlet: "outlet",
                     HMServiceTypeLightbulb: "light", HMServiceTypeFan: "fan",
                     HMServiceTypeAirPurifier: "air_purifier", HMServiceTypeHeaterCooler: "heater_cooler",
                     HMServiceTypeThermostat: "thermostat", HMServiceTypeHumidifierDehumidifier: "humidifier_dehumidifier",
                     HMServiceTypeAccessoryInformation: "accessory_information"]
        return names[type] ?? type
    }
}
