import SwiftUI
import HomeKit
import PDFKit
import ImageIO
import Combine

@MainActor
final class HomeBoardModel: ObservableObject {
    let app: AppModel
    @Published var homes: [BoardHome] = []
    @Published var homeID = ""
    @Published var values: [String: ScalarValue] = [:]
    @Published var reading = Set<String>()
    @Published private(set) var refreshing = false
    private var refreshGate = RefreshGate()
    private var stateRevision: UInt64 = 0
    @Published var pendingPower = Set<String>()
    @Published var unconfirmed = Set<String>()
    @Published var busy = false
    @Published var notice = ""
    @Published var error: String?
    @Published var plan = FloorPlanLayout(homeID: "") {
        didSet { if cloud.isShared && !installingCloudLayout { plan = oldValue } }
    }
    let cloud = LayoutCloudSync()
    var installingCloudLayout = false
    @Published var layoutEditing = false
    private var cloudChanges: AnyCancellable?
    @Published private(set) var layoutSource: LayoutSource = .personal
    @Published private(set) var layoutStorageReady = false
    var canEditLayout: Bool { layoutStorageReady && layoutSource == .personal && cloud.editable }
    var canSwitchLayout: Bool { layoutStorageReady && !homeID.isEmpty && !layoutEditing && !cloud.busy && !cloud.conflict }
    var canSwitchHome: Bool { !busy && pendingPower.isEmpty && !layoutEditing }
    private let lastHomeKey = "homeBoard.lastSelectedHomeID"

    @Published var planImage: UIImage?
    @Published var layoutUndo: [FloorPlanLayout] = []
    init(app: AppModel) {
        self.app = app
        cloud.board = self
        cloudChanges = cloud.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var home: BoardHome? { homes.first { $0.id == homeID } }
    var devices: [BoardDevice] { home?.accessories ?? [] }
    var rooms: [BoardRoom] { home?.rooms.filter { !$0.isDefault } ?? [] }
    var scenes: [BoardScene] { home?.scenes ?? [] }

    func refresh() {
        do {
            let snapshot = app.home.snapshot()
            let data = try JSONSerialization.data(withJSONObject: snapshot["homes"] ?? [])
            homes = try JSONDecoder().decode([BoardHome].self, from: data)
            let chosen = HomeSelection.resolve(available:homes.map(\.id),current:homeID,remembered:UserDefaults.standard.string(forKey:lastHomeKey)) ?? ""
            if chosen != homeID { selectHome(chosen) }
            var cachedValues = values
            for h in app.home.manager?.homes ?? [] {
                for a in h.accessories {
                    for s in a.services where s.isUserInteractive {
                        for c in s.characteristics where c.properties.contains(HMCharacteristicPropertyReadable) {
                            if let raw = c.value, let normalized = try? Commands.normalizeScalar(raw, format: c.metadata?.format ?? ""), let value = try? ScalarValue.from(normalized) {
                                cachedValues[c.uniqueIdentifier.uuidString] = value
                            }
                        }
                    }
                }
            }
            if cachedValues != values { stateRevision &+= 1; values = cachedValues }
        } catch { self.error = "无法读取家庭清单：\(error.localizedDescription)" }
    }
    func selectHome(_ id: String) {
        guard id != homeID, id.isEmpty || homes.contains(where: { $0.id == id }) else { return }
        // Access revocation must still clear an unavailable family during an operation.
        guard canSwitchHome || !homes.contains(where: { $0.id == homeID }) else { return }
        if !id.isEmpty { UserDefaults.standard.set(id,forKey:lastHomeKey) }
        stateRevision &+= 1; notice = ""; error = nil
        installingCloudLayout = true
        defer { installingCloudLayout = false }
        homeID = id; layoutStorageReady = false; layoutSource = .personal
        plan = FloorPlanLayout(homeID: id); planImage = nil; layoutUndo = []
        guard !id.isEmpty else { cloud.selectHome(id); return }
        do {
            layoutSource = try LayoutSourceStore.prepare(in: homeDirectory())
            layoutStorageReady = true; cloud.selectHome(id)
            #if targetEnvironment(simulator) && DEBUG
            if app.home.isDemo { plan = MobileDemo.layout(); return }
            #endif
            let loaded = try readLayout(in: planDirectory())
            plan = loaded.0; planImage = loaded.1
        } catch {
            layoutStorageReady = false; cloud.selectHome(id)
            self.error = "读取本地户型布局失败：\(error.localizedDescription)"
        }
    }
    private func readLayout(in folder: URL) throws -> (FloorPlanLayout, UIImage?) {
        let bundleURL = folder.appendingPathComponent("layout-bundle.json")
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            let bundle = try JSONDecoder().decode(StoredLayoutBundle.self, from: Data(contentsOf: bundleURL))
            return (try FloorPlanLayout.decode(JSONEncoder().encode(bundle.layout), homeID: homeID), bundle.image.flatMap(UIImage.init(data:)))
        }
        var layout = FloorPlanLayout(homeID: homeID)
        let file = folder.appendingPathComponent("layout.json")
        if FileManager.default.fileExists(atPath: file.path) { layout = try FloorPlanLayout.decode(Data(contentsOf: file), homeID: homeID) }
        return (layout, UIImage(contentsOfFile: folder.appendingPathComponent("floorplan.jpg").path))
    }
    func switchLayoutSource(_ source: LayoutSource) {
        guard source != layoutSource else { return }
        guard canSwitchLayout else { error = "请先结束布局编辑，并等待当前同步完成"; return }
        do { try activateLayoutSource(source) }
        catch { self.error = "切换布局失败：" + error.localizedDescription }
    }
    /// CloudKit may call this after fetching a share; no asynchronous work can cross this switch.
    func activateLayoutSource(_ source: LayoutSource) throws {
        guard source != layoutSource else { return }
        guard layoutStorageReady, !layoutEditing else { throw CommandFailure("layout_busy", "请先结束布局编辑") }
        let root = try homeDirectory()
        let loaded = try readLayout(in: LayoutSourceStore.directory(source, in: root))
        try LayoutSourceStore.select(source, in: root)
        installingCloudLayout = true
        defer { installingCloudLayout = false }
        layoutSource = source; cloud.selectHome(homeID)
        plan = loaded.0; planImage = loaded.1; layoutUndo = []
        error = nil; notice = "已切换到" + source.title
    }
    func characteristic(_ id: String) -> (BoardDevice, BoardCharacteristic)? {
        for device in devices {
            for service in device.services {
                if let c = service.characteristics.first(where: { $0.id == id }) { return (device, c) }
            }
        }
        return nil
    }
    func isOn(_ device: BoardDevice) -> Bool? {
        guard let c = device.power, !unconfirmed.contains(c.id), let value = values[c.id] else { return nil }
        switch value { case .bool(let b): return b; case .number(let n): return n != 0; default: return nil }
    }
    func visualState(_ device: BoardDevice) -> DeviceVisualState {
        DeviceVisualState(isOn: isOn(device), reachable: device.reachable, pending: pendingPower.contains(device.id), hasPower: device.power != nil)
    }
    func sensorSummary(_ device: BoardDevice) -> String {
        device.sensors.compactMap { $0.sensorText(device.reachable && !unconfirmed.contains($0.id) ? values[$0.id] : nil) }.joined(separator: " · ")
    }
    func status(_ device: BoardDevice) -> String {
        if pendingPower.contains(device.id) { return "处理中…" }
        if !device.reachable { return "暂不可达" }
        var parts: [String] = []
        if let active = isOn(device) { parts.append(active ? "已开启" : "已关闭") }
        else if device.power != nil { parts.append("状态待刷新") }
        let sensors = sensorSummary(device)
        if !sensors.isEmpty { parts.append(sensors) }
        return parts.isEmpty ? "查看详情" : parts.joined(separator: " · ")
    }
    @discardableResult
    func read(_ characteristic: BoardCharacteristic, quiet: Bool = false) async -> Bool {
        guard characteristic.readable, !reading.contains(characteristic.id) else { return false }
        reading.insert(characteristic.id); defer { reading.remove(characteristic.id) }
        do {
            let result = try await app.home.perform("read_characteristic", arguments: ["characteristic_id": characteristic.id])
            guard let raw = result["value"] else { throw CommandFailure("missing_value", "设备未返回状态") }
            stateRevision &+= 1
            values[characteristic.id] = try ScalarValue.from(raw); unconfirmed.remove(characteristic.id)
            return true
        } catch {
            stateRevision &+= 1
            unconfirmed.insert(characteristic.id)
            if !quiet { self.error = "读取\(characteristic.label)失败：\(error.localizedDescription)" }
            return false
        }
    }
    func readDevice(_ device: BoardDevice) async {
        guard device.reachable else { return }
        let chars = device.services.filter(\.userInteractive).flatMap(\.characteristics).filter { $0.readable && ["bool", "float", "int", "uint8", "uint16", "uint32", "uint64", "string"].contains($0.metadata?.format ?? "") }
        // At most four concurrent reads; never subscribe to cameras or binary streams.
        for start in stride(from: 0, to: chars.count, by: 4) {
            await withTaskGroup(of: Void.self) { group in
                for c in chars[start..<min(start + 4, chars.count)] { group.addTask { _ = await self.read(c, quiet: true) } }
            }
        }
    }
    func refreshPowerStates(automatic: Bool = false) async {
        guard !Task.isCancelled, refreshGate.begin(at:ProcessInfo.processInfo.systemUptime,automatic:automatic) else { return }
        refreshing = true
        defer { refreshGate.finish(at:ProcessInfo.processInfo.systemUptime); refreshing = false }
        refresh()
        let requestedHome = homeID, requestedRevision = stateRevision
        let candidates = devices.filter { $0.reachable && !pendingPower.contains($0.id) }.flatMap { device in
            [device.power].compactMap { $0 } + device.sensors
        }
        var seen = Set<String>()
        let chars = candidates.filter { $0.readable && !reading.contains($0.id) && seen.insert($0.id).inserted }
        var received: [String:ScalarValue] = [:], failed = Set<String>()
        for start in stride(from:0,to:chars.count,by:4) {
            guard !Task.isCancelled, homeID == requestedHome, stateRevision == requestedRevision else { return }
            // The round gate controls the refresh button; only in-flight characteristics
            // are reserved so a slow device does not block controls for every other device.
            let batch = chars[start..<min(start+4,chars.count)].filter { !reading.contains($0.id) }
            let ids = Set(batch.map(\.id)); reading.formUnion(ids)
            defer { reading.subtract(ids) }
            await withTaskGroup(of:(String,ScalarValue?).self) { group in
                for c in batch {
                    group.addTask { @MainActor in
                        guard !Task.isCancelled else { return (c.id,nil) }
                        do {
                            let result = try await self.app.home.perform("read_characteristic",arguments:["characteristic_id":c.id])
                            guard let raw = result["value"] else { return (c.id,nil) }
                            return (c.id,try ScalarValue.from(raw))
                        } catch { return (c.id,nil) }
                    }
                }
                for await (id,value) in group {
                    if let value { received[id] = value } else { failed.insert(id) }
                }
            }
        }
        guard !Task.isCancelled, homeID == requestedHome, stateRevision == requestedRevision else { return }
        // A foreground read or command wins over older results from this batch.
        // Publish one consolidated state update at completion. Preserve unrelated reads/writes.
        var updated = values
        for (id,value) in received { updated[id] = value }
        if updated != values { values = updated }
        let uncertain = unconfirmed.subtracting(received.keys).union(failed)
        if uncertain != unconfirmed { unconfirmed = uncertain }
    }
    func togglePower(_ device: BoardDevice, refreshFirst: Bool = false) async {
        guard let current = devices.first(where: { $0.id == device.id }), current.reachable,
              let c = current.power, !busy, pendingPower.isEmpty else { return }
        if refreshFirst && !current.supportsDirectPower { return }
        pendingPower.insert(current.id)
        defer { pendingPower.remove(current.id) }
        if refreshFirst {
            notice = "正在读取\(current.name)…"
            // A background refresh may already be reading this characteristic.
            // Wait for it, then read afresh rather than dropping the user's click.
            while reading.contains(c.id) {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            guard await read(c) else { notice = "未能读取状态，未发送开关指令"; return }
        }
        guard let on = isOn(current) else { await read(c); return }
        let value: ScalarValue = c.metadata?.format == "bool" ? .bool(!on) : .number(on ? 0 : 1)
        await write(c, value: value)
    }
    func write(_ c: BoardCharacteristic, value: ScalarValue) async {
        if await run(BoardCommand(tool: "write_characteristic", arguments: ["characteristic_id": c.id, "value": value.json])) != nil {
            unconfirmed.insert(c.id)
            if c.readable {
                if await read(c) { notice = "状态已同步" }
                else { notice = "指令已发送，状态待确认" }
            } else { values.removeValue(forKey: c.id) }
        }
    }
    /// Local button clicks use the same validation and shared mutation lock as MCP,
    /// without enabling remote control credentials or the HTTP write switch.
    func run(_ command: BoardCommand) async -> [String: Any]? {
        guard !busy else { return nil }
        stateRevision &+= 1
        busy = true; notice = "正在处理…"
        defer { busy = false; refresh() }
        do {
            var args = command.arguments; let key = UUID().uuidString; args["request_id"] = key
            try Commands.validateArguments(command.tool, args)
            try HomeTopology(app.home.snapshot()).validate(command.tool, args)
            let fingerprint = try JSONSerialization.data(withJSONObject: ["tool": command.tool, "arguments": args], options: [.sortedKeys])
            _ = try app.commands.operations.submit(key, tool: command.tool, fingerprint: fingerprint) { [app] in
                try await app.home.perform(command.tool, arguments: args)
            }
            while true {
                let operation = try app.commands.operations.get(key)
                let state = operation["state"] as? String ?? ""
                if state == "succeeded" { notice = "操作已完成"; return operation["result"] as? [String: Any] ?? [:] }
                if state != "running" {
                    let message = (operation["error"] as? [String: Any])?["message"] as? String
                    throw CommandFailure(state, message ?? "操作结果尚未确认。请先刷新设备或场景，勿重复提交。")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        } catch { notice = "操作未完成"; self.error = error.localizedDescription; return nil }
    }
    func saveScene(baseline: BoardScene?, name: String, actions: [SceneDraftAction]) async -> Bool {
        refresh()
        do {
            let commands = try SceneEditPlanner.plan(baseline: baseline, current: scenes.first { $0.id == baseline?.id }, homeID: homeID, name: name, actions: actions)
            let topology = try HomeTopology(app.home.snapshot())
            for command in commands {
                try Commands.validateArguments(command.tool, command.arguments, preview: true)
                try topology.validate(command.tool, command.arguments)
            }
            var completed = 0
            for command in commands {
                guard await run(command) != nil else {
                    error = (error ?? "保存失败") + "\n已完成 \(completed)/\(commands.count) 个步骤。请关闭编辑并重新检查场景，已完成的更改不会自动撤销。"
                    return false
                }
                completed += 1
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func planDirectory() throws -> URL {
        guard layoutStorageReady else { throw CommandFailure("layout_storage", "布局存储尚未准备好") }
        return try LayoutSourceStore.directory(layoutSource, in: homeDirectory())
    }
    func homeDirectory() throws -> URL {
        guard UUID(uuidString: homeID) != nil else { throw CommandFailure("invalid_home", "请先选择家庭") }
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HomeBoard", isDirectory: true).appendingPathComponent(homeID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
    func importPlan(_ url: URL) {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return }

        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 30 * 1024 * 1024 else { throw CommandFailure("file_size", "请选择不超过 30 MB 的图片或 PDF") }
            let data = try Data(contentsOf: url)
            let image: UIImage
            if url.pathExtension.lowercased() == "pdf" {
                guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { throw CommandFailure("invalid_pdf", "无法打开 PDF，请检查是否加密或损坏") }
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width > 0, bounds.height > 0 else { throw CommandFailure("invalid_pdf", "PDF 页面尺寸无效") }
                let scale = 2400 / max(bounds.width, bounds.height)
                image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            } else {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw CommandFailure("invalid_image", "无法读取该图片，请使用 PNG、JPEG 或 HEIC") }
                image = UIImage(cgImage: cg)
            }
            guard let jpg = image.jpegData(compressionQuality: 0.92) else { throw CommandFailure("image_encoding", "无法保存户型图") }
            let destination = try planDirectory().appendingPathComponent("floorplan.jpg")
            try jpg.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            planImage = image; try persistPlan(); notice = "户型图已导入。打开“编辑布局”即可放置房间和设备。"
        } catch { self.error = error.localizedDescription }
    }
    func place(_ id: String, room: Bool, at point: PlanPoint? = nil) {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return }

        let count = plan.devices.count + plan.rooms.count
        let position = point ?? PlanPoint(x: 0.2 + Double(count % 4) * 0.2, y: 0.25 + Double((count / 4) % 3) * 0.25)
        if room { plan.rooms[id] = position } else { plan.devices[id] = position }
        do { try persistPlan() } catch { self.error = "布局保存失败：\(error.localizedDescription)" }
    }
    func unplace(_ id: String, room: Bool) {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return }

        if room { plan.rooms.removeValue(forKey: id) } else { plan.devices.removeValue(forKey: id) }
        do { try persistPlan() } catch { self.error = error.localizedDescription }
    }
    func removePlan() {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return }

        do {
            let folder = try planDirectory()
            let backup = folder.appendingPathComponent("RemovedLayouts", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for name in ["floorplan.jpg", "layout.json"] {
                let file = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: file, to: backup.appendingPathComponent(name)) }
            }
            planImage = nil; plan = FloorPlanLayout(homeID: homeID); try persistPlan()
            notice = "户型图已从首页移除；原始文件未改动，本地布局副本已保留。"
        } catch { self.error = "移除户型图失败：\(error.localizedDescription)" }
    }
    func finishRoomOutline(_ outline: SpatialRoom) -> Bool {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return false }

        let previous = plan
        if plan.spatial == nil { plan.spatial = SpatialLayout() }
        if let index = plan.spatial?.rooms.firstIndex(where: { $0.id == outline.id }) { plan.spatial?.rooms[index] = outline }
        else { plan.spatial?.rooms.append(outline) }
        do {
            try plan.spatial?.validate(); try persistPlan()
            layoutUndo.append(previous)
            if layoutUndo.count > 30 { layoutUndo.removeFirst() }
            notice = "房间已闭合，可继续拖动角点调整"
            return true
        } catch { plan = previous; self.error = "闭合未保存：\(error.localizedDescription)"; return false }
    }
    func snapLayoutPoint(_ point: PlanPoint, width: Double, height: Double,
                         movingRoom: String? = nil, vertex: Int? = nil,
                         excludingRoom: String? = nil, draft: [PlanPoint] = []) -> LayoutSnapResult {
        var anchors = draft
        var edges: [(PlanPoint, PlanPoint)] = []
        for room in plan.spatial?.rooms ?? [] where room.id != excludingRoom {
            for i in room.points.indices {
                let next = (i+1) % room.points.count
                if room.id != movingRoom || i != vertex { anchors.append(room.points[i]) }
                if room.id == movingRoom && (i == vertex || next == vertex) { continue }
                edges.append((room.points[i], room.points[next]))
            }
        }
        return LayoutSnap.resolve(point, width: width, height: height, anchors: anchors, edges: edges,
                                  closeTo: draft.count >= 3 ? draft.first : nil)
    }
    func insertRoomVertex(_ room: SpatialRoom, on edge: Int, fraction: Double) {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return }

        do { try replaceRoomOutline(room, with: room.insertingVertex(on: edge, fraction: fraction), notice: "已添加角点，拖动新点调整房间形状") }
        catch { self.error = error.localizedDescription }
    }
    func removeRoomVertex(_ room: SpatialRoom, at vertex: Int) {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return }

        do { try replaceRoomOutline(room, with: room.removingVertex(at: vertex), notice: "已删除角点，可点撤销恢复") }
        catch { self.error = error.localizedDescription }
    }
    private func replaceRoomOutline(_ room: SpatialRoom, with replacement: SpatialRoom, notice: String) throws {
        guard let index = plan.spatial?.rooms.firstIndex(where: { $0.id == room.id }),
              plan.spatial?.rooms[index] == room else { throw CommandFailure("room_changed", "房间轮廓已变化，请重新选择角点。") }
        let previous = plan
        plan.spatial?.rooms[index] = replacement
        do { try persistPlan() } catch { plan = previous; throw error }
        layoutUndo.append(previous)
        if layoutUndo.count > 30 { layoutUndo.removeFirst() }
        self.notice = notice
    }
    func checkpointLayout() {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return }
 layoutUndo.append(plan); if layoutUndo.count > 30 { layoutUndo.removeFirst() } }
    func undoLayout() {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return }
 guard let previous = layoutUndo.popLast() else { return }; plan = previous; saveLayout() }
    func addFurniture(_ kind: String, at point: PlanPoint) -> String {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return "" }

        checkpointLayout()
        let width = ["plant": 0.035, "toilet": 0.04, "sink": 0.06, "stove": 0.07, "fridge": 0.06, "counter": 0.10, "rangeHood": 0.07][kind] ?? 0.08
        let depth = ["bed": 0.15, "toilet": 0.08, "sink": 0.05, "stove": 0.055, "fridge": 0.07, "counter": 0.055, "rangeHood": 0.045][kind] ?? 0.06
        let item = SpatialFurniture(kind: kind, point: point, width: width, depth: depth)
        if plan.spatial == nil { plan.spatial = SpatialLayout() }
        plan.spatial?.furniture.append(item); saveLayout(); return "furniture:\(item.id)"
    }
    func addModel(_ asset: FurnitureAsset, at point: PlanPoint) -> String {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return "" }

        let previous = plan
        let aspect = Double((planImage?.size.height ?? 800)/(planImage?.size.width ?? 1000))
        var item = SpatialFurniture(kind:"model",point:PlanPoint(x:min(1,max(0,point.x)),y:min(1,max(0,point.y))),width:min(1,max(0.005,asset.width/12)),depth:min(1,max(0.005,asset.depth/(12*aspect))))
        item.assetID = asset.id
        if plan.spatial == nil { plan.spatial = SpatialLayout() }
        plan.spatial?.furniture.append(item)
        do { try plan.spatial?.validate(); try persistPlan(); layoutUndo.append(previous); if layoutUndo.count > 30 { layoutUndo.removeFirst() } }
        catch { plan = previous; self.error = "模型摆放保存失败：\(error.localizedDescription)"; return "" }
        return "furniture:\(item.id)"
    }
    func saveLayout() {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return }

        do { try plan.spatial?.validate(); try persistPlan() } catch { self.error = "布局保存失败：\(error.localizedDescription)" }
    }
    var layoutGenerationContext: String {
        let image = planImage?.size
        let context: [String: Any] = [
            "imageImported": image != nil,
            "modelAssets": FurnitureLibrary.shared.assets.map { ["assetID": $0.id, "name": $0.title, "category": $0.category] },
            "imageWidth": image?.width ?? 1000, "imageHeight": image?.height ?? 800,
            "rooms": rooms.map { room in ["name": room.name, "devices": devices.filter { $0.roomId == room.id }.map(\.name)] as [String: Any] }
        ]
        let data = (try? JSONSerialization.data(withJSONObject: context, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    func prepareCalibration(_ url: URL) -> LayoutImportReview? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 2_000_000 else { throw CommandFailure("invalid_layout", "布局 JSON 必须小于 2 MB") }
            let input = try SpatialCalibration.decode(Data(contentsOf: url))
            for furniture in input.furniture where furniture.kind == "model" {
                guard FurnitureLibrary.shared.asset(furniture.assetID) != nil else { throw CommandFailure("missing_model","未找到模型 \(furniture.assetID ?? "")，请先导入对应模型或使用素材库中的 assetID。") }
            }
            let candidate = try input.applying(to: plan, homeRooms: rooms, devices: devices)
            return LayoutImportReview(baseline: plan, candidate: candidate)
        } catch { self.error = "导入空间布局失败：\(error.localizedDescription)"; return nil }
    }
    func applyCalibration(_ review: LayoutImportReview) -> Bool {
        guard canEditLayout else { error = "此布局当前不可编辑：共享成员仅可查看，或同步正在进行"; return false }

        do {
            guard plan == review.baseline else { throw CommandFailure("layout_changed", "布局在预览期间发生变化，请重新导入") }
            try review.candidate.spatial?.validate()
            let backup = try planDirectory().appendingPathComponent("layout-before-import-\(UUID().uuidString).json")
            try JSONEncoder().encode(plan).write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try persistPlan(review.candidate)
            checkpointLayout(); plan = review.candidate
            error = nil; notice = "空间布局已导入；旧布局已备份，可撤销。请检查轮廓、家具和设备位置。"
            return true
        } catch { self.error = "导入未完成：\(error.localizedDescription)"; return false }
    }
    private func persistPlan(_ layout: FloorPlanLayout? = nil) throws {
        guard canEditLayout else { throw CommandFailure("layout_readonly", "当前布局不可编辑") }
        let value = layout ?? plan
        // Mark pending before replacing the local snapshot so an interrupted disk write cannot lose dirty state.
        try cloud.localChanged()
        let folder = try planDirectory()
        try JSONEncoder().encode(StoredLayoutBundle(layout: value, image: planImage?.jpegData(compressionQuality: 0.92))).write(to: folder.appendingPathComponent("layout-bundle.json"), options: .atomic)
        let url = folder.appendingPathComponent("layout.json")
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
