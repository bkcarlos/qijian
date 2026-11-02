import SwiftUI

struct ScalarEditor: View {
    let characteristic: BoardCharacteristic
    @Binding var value: ScalarValue
    private var number: Binding<Double> { Binding(get: { value.number ?? characteristic.initialValue.number ?? 0 }, set: { value = .number($0) }) }
    var body: some View {
        if characteristic.metadata?.format == "bool" {
            Toggle("开启", isOn: Binding(get: { if case .bool(let b) = value { return b }; return false }, set: { value = .bool($0) })).labelsHidden()
        } else if characteristic.metadata?.format == "string" {
            TextField("目标值", text: Binding(get: { if case .string(let s) = value { return s }; return "" }, set: { value = .string($0) })).textFieldStyle(.roundedBorder)
        } else if let choices = characteristic.metadata?.validValues, !choices.isEmpty {
            Picker("目标值", selection: number) { ForEach(choices, id: \.self) { Text(choiceLabel($0)).tag($0) } }.labelsHidden().frame(minWidth: 130)
        } else {
            HStack(spacing: 8) {
                TextField("数值", value: number, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                Text(characteristic.metadata?.units == "celsius" ? "°C" : characteristic.metadata?.units == "percentage" ? "%" : "").foregroundStyle(.secondary)
                if let min = characteristic.metadata?.minimum, let max = characteristic.metadata?.maximum, min < max {
                    Stepper("目标值", value: number, in: min...max, step: characteristic.metadata?.step ?? 1).labelsHidden()
                }
            }
        }
    }
    private func choiceLabel(_ value: Double) -> String {
        if characteristic.shortType == "000000B0" || characteristic.shortType == "000000B6" { return value == 0 ? "关闭" : "开启" }
        if characteristic.shortType == "000000B2" { return [0: "自动", 1: "制热", 2: "制冷"][Int(value)] ?? "\(Int(value))" }
        if characteristic.shortType == "00000033" { return [0: "关闭", 1: "制热", 2: "制冷", 3: "自动"][Int(value)] ?? "\(Int(value))" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

struct DeviceControlRow: View {
    @ObservedObject var board: HomeBoardModel
    let characteristic: BoardCharacteristic
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var draft: ScalarValue
    @State private var dirty = false
    init(board: HomeBoardModel, characteristic: BoardCharacteristic) {
        self.board = board; self.characteristic = characteristic
        _draft = State(initialValue: board.values[characteristic.id] ?? characteristic.initialValue)
    }
    var body: some View {
        let layout = sizeClass == .compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 5) {
                Text(characteristic.label)
                Text("当前：\(board.values[characteristic.id]?.text ?? "未知")\(characteristic.metadata?.units == "celsius" ? " °C" : "")").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if characteristic.editable {
                    ScalarEditor(characteristic: characteristic, value: Binding(get: { draft }, set: { draft = $0; dirty = true }))
                    Button("应用") {
                        Task { await board.write(characteristic, value: draft); dirty = false; draft = board.values[characteristic.id] ?? draft }
                    }.buttonStyle(.bordered).disabled(board.busy)
                }
                if characteristic.readable {
                    Button { Task { await board.read(characteristic) } } label: { Image(systemName: board.reading.contains(characteristic.id) ? "hourglass" : "arrow.clockwise").frame(minWidth: 30, minHeight: 36) }
                        .buttonStyle(.borderless).disabled(board.reading.contains(characteristic.id)).accessibilityLabel("读取\(characteristic.label)")
                }
            }
        }.padding(.vertical, 6)
            .onChange(of: board.values[characteristic.id]) { value in if !dirty, let value { draft = value } }
    }
}

struct DeviceDetailView: View {
    @ObservedObject var board: HomeBoardModel
    let deviceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var room = ""
    private var device: BoardDevice? { board.devices.first { $0.id == deviceID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if let device { Image(systemName: device.icon).font(.title).foregroundStyle(.teal); VStack(alignment: .leading) { Text(device.name).font(.title2.bold()); Text("\(device.roomName) · \(board.status(device))").foregroundStyle(.secondary).font(.callout) } }
                Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error = board.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let device {
                        if let accessory = board.app.home.manager?.homes
                            .first(where: { $0.uniqueIdentifier.uuidString == board.homeID })?.accessories
                            .first(where: { $0.uniqueIdentifier.uuidString == deviceID }),
                           let streamControl = accessory.cameraProfiles?.first?.streamControl {
                            CameraLiveView(control: streamControl).id(deviceID)
                        }
                        if let power = device.power {
                            HStack {
                                Text("设备电源").font(.headline); Spacer()
                                Button(board.isOn(device) == nil ? "读取状态" : board.isOn(device) == true ? "关闭设备" : "开启设备") { Task { await board.togglePower(device) } }
                                    .buttonStyle(.borderedProminent).tint(AppTheme.selection).disabled(board.busy || board.reading.contains(power.id) || !device.reachable)
                            }
                        }
                        ForEach(device.services.filter(\.userInteractive)) { service in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(service.name).font(.headline)
                                ForEach(service.characteristics.filter { $0.editable || ($0.readable && ["bool", "int", "uint8", "uint16", "uint32", "uint64", "float", "string"].contains($0.metadata?.format ?? "")) }) { c in
                                    DeviceControlRow(board: board, characteristic: c)
                                }
                            }.padding(18).background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        }
                        DisclosureGroup("名称与房间") {
                            VStack(spacing: 14) {
                                TextField("设备名称", text: $name).textFieldStyle(.roundedBorder)
                                Picker("房间", selection: $room) { ForEach(board.home?.rooms ?? []) { Text($0.name).tag($0.id) } }
                                Button("保存设备信息") {
                                    Task {
                                        if name != device.name, await board.run(BoardCommand(tool: "rename_accessory", arguments: ["accessory_id": device.id, "name": name])) == nil { return }
                                        if room != device.roomId { _ = await board.run(BoardCommand(tool: "move_accessory", arguments: ["accessory_id": device.id, "room_id": room])) }
                                    }
                                }.disabled(board.busy || name.isEmpty)
                            }.padding(.top, 12)
                        }
                    } else { Text("该设备已不在当前家庭中。") }
                }
            }
            if board.busy { ProgressView("正在操作…") }
            Text("电源按钮直接控制设备；其他参数修改后点击“应用”。状态可能受网络和设备可达性影响。").font(.caption).foregroundStyle(.secondary)
        }.padding(26).homeEditorFrame(minWidth: 660, idealWidth: 740, minHeight: 540, idealHeight: 680)
            .task { if let device { name = device.name; room = device.roomId; await board.readDevice(device) } }
    }
}

struct SceneEditorView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var board: HomeBoardModel
    let scene: BoardScene?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var actions: [SceneDraftAction]
    @State private var saving = false
    @State private var failedSave = false
    init(board: HomeBoardModel, scene: BoardScene?) {
        self.board = board; self.scene = scene
        _name = State(initialValue: scene?.name ?? "")
        _actions = State(initialValue: scene?.actions.compactMap { action in
            guard action.kind == "characteristic_write", let id = action.characteristicId, let value = action.value else { return nil }
            return SceneDraftAction(characteristicId: id, value: value)
        } ?? [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            let headerLayout = sizeClass == .compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
            headerLayout {
                VStack(alignment: .leading, spacing: 5) { Text(scene == nil ? "新建场景" : "编辑场景").font(.title2.bold()); Text("保存只修改动作配置，不会执行设备操作。").font(.callout).foregroundStyle(.secondary) }
                HStack {
                Spacer(); Button("取消") { dismiss() }.disabled(saving)
                Button(saving ? "正在保存…" : "保存场景") {
                    saving = true
                    Task {
                        let success = await board.saveScene(baseline: scene, name: name.trimmingCharacters(in: .whitespacesAndNewlines), actions: actions)
                        saving = false
                        if success { dismiss() } else { failedSave = true }
                    }
                }.buttonStyle(.borderedProminent).tint(AppTheme.selection).disabled(saving || board.busy || failedSave || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut("s", modifiers: .command)
                }
            }
            TextField("场景名称，例如：准备睡觉", text: $name).textFieldStyle(.roundedBorder).font(.title3).disabled(scene?.userDefined == false)
            if let error = board.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("设备动作 · \(actions.count)").font(.headline)
                Spacer()
                Menu("添加设备动作") {
                    ForEach(board.devices.filter { !$0.controls.isEmpty }) { device in
                        Menu("\(device.roomName) · \(device.name)") {
                            ForEach(device.controls.filter { c in !actions.contains { $0.characteristicId == c.id } }) { c in
                                Button(c.label) { actions.append(SceneDraftAction(characteristicId: c.id, value: board.values[c.id] ?? c.initialValue)) }
                            }
                        }
                    }
                }.disabled(saving || failedSave)
            }
            ScrollView {
                VStack(spacing: 12) {
                    if actions.isEmpty { VStack(spacing: 10) { Image(systemName: "sparkles").font(.largeTitle); Text("为场景添加第一个设备动作").foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(45) }
                    ForEach($actions) { $action in
                        SceneActionEditorRow(board: board, action: $action) {
                            actions.removeAll { $0.characteristicId == action.characteristicId }
                        }.disabled(saving || failedSave)
                    }
                    if let scene {
                        let unsupported = scene.actions.filter { $0.kind != "characteristic_write" || $0.characteristicId == nil || $0.value == nil }.count
                        if unsupported > 0 { Text("另有 \(unsupported) 个暂不支持编辑的动作，将完整保留。").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if failedSave { Text("为避免覆盖部分已完成的修改，请关闭编辑并重新打开场景后再保存。").font(.caption).foregroundStyle(.orange) }
            Text("编辑现有场景时，会检查它是否在其他位置被改动。多项修改可能分步完成，失败时会明确显示进度。").font(.caption).foregroundStyle(.secondary)
        }.padding(26).homeEditorFrame(minWidth: 720, idealWidth: 800, minHeight: 560, idealHeight: 680)
    }
}

private struct SceneActionEditorRow: View {
    @ObservedObject var board: HomeBoardModel
    @Binding var action: SceneDraftAction
    let remove: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        Group {
            if sizeClass == .compact {
                VStack(alignment: .leading, spacing: 16) {
                    title
                    HStack { editor; Spacer(minLength: 8); removeButton }
                }
            } else {
                HStack(spacing: 16) { title; Spacer(); editor; removeButton }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private var title: some View {
        if let (device,c) = board.characteristic(action.characteristicId) {
            HStack(spacing: 12) {
                Image(systemName: device.icon).font(.title3).foregroundStyle(.teal).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.name).font(.headline)
                    Text("\(device.roomName) · \(c.label)").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else { Text("设备暂不可见") }
    }
    @ViewBuilder private var editor: some View {
        if let (_, c) = board.characteristic(action.characteristicId) { ScalarEditor(characteristic: c, value: $action.value) }
        else { Text(action.value.text).foregroundStyle(.secondary) }
    }
    private var removeButton: some View {
        Button(role: .destructive, action: remove) { Image(systemName: "minus.circle").frame(width: 36, height: 36) }
            .buttonStyle(.borderless).accessibilityLabel("移除这个设备动作")
    }
}

extension View {
    @ViewBuilder func homeEditorFrame(minWidth: CGFloat, idealWidth: CGFloat, minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil) -> some View {
        #if targetEnvironment(macCatalyst)
        self.frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight)
        #else
        self.frame(maxWidth: .infinity, maxHeight: minHeight == nil ? nil : .infinity)
        #endif
    }
}
