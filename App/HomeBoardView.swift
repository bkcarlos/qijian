import SwiftUI
import UniformTypeIdentifiers

private let boardAccent = AppTheme.accent
private let boardBackground = AppTheme.background

struct SceneSheet: Identifiable { let id = UUID(); var scene: BoardScene? }

struct HomeBoardView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var homeStore: HomeStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var board: HomeBoardModel
    @State private var showingHomes = false
    @State private var showingLayoutSettings = false
    @State private var section: String? = "home"
    @State private var selectedDevice: BoardDevice?
    @State private var sceneSheet: SceneSheet?
    @State private var addingDevices: DeviceSetupGuideSession?
    @State private var sceneToRun: BoardScene?
    @State private var sceneToDelete: BoardScene?
    @State private var importing = false
    @State private var spatialWorkspace = false
    @State private var layoutMode = "2d"
    @State private var planViewport = PlanViewport()
    @State private var planBackground = false
    @State private var planRotation: Int?
    @State private var overviewCanvasSize = CGSize(width: 1, height: 1)
    private var showing3D: Bool { layoutMode == "3d" }
    @State private var spatialCamera = SpatialCamera()
    @State private var spatialSelection: String?
    @State private var sidebarVisible = true
    @State private var showingCanvasHelp = false
    @State private var showingNotice = false
    init(app: AppModel) {
        self.app = app; homeStore = app.home
        _board = StateObject(wrappedValue: HomeBoardModel(app: app))
    }
    var body: some View {
        Group {
            if spatialWorkspace && board.canEditLayout {
                SpatialWorkspace(board: board, initialMode: layoutMode, onClose: { spatialWorkspace = false })
            } else {
                dashboard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if targetEnvironment(macCatalyst)
        .ignoresSafeArea(.container, edges: .top)
        #endif
        .background(boardBackground)
        .overlay(alignment: .bottomTrailing) {
            if showingNotice && !board.notice.isEmpty {
                HStack(spacing: 8) {
                    if board.busy || !board.pendingPower.isEmpty { ProgressView().controlSize(.small) }
                    Text(board.notice).font(.callout)
                    Button { showingNotice = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭操作提示")
                }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.08), radius: 8).padding(20)
            }
        }
        .task(id: board.notice) {
            showingNotice = !board.notice.isEmpty
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            if !board.busy && board.pendingPower.isEmpty { showingNotice = false }
        }
        .tint(boardAccent)
        .modifier(CloudLayoutLifecycle(board: board))
        .onChange(of: board.homeID) { _ in spatialCamera = SpatialCamera(); planViewport = PlanViewport(); planRotation = nil; spatialSelection = nil; selectedDevice = nil; sceneSheet = nil; sceneToRun = nil; sceneToDelete = nil; addingDevices = nil; spatialWorkspace = false; section = "home" }
        .onChange(of: board.layoutSource) { _ in spatialCamera = SpatialCamera(); planViewport = PlanViewport(); planRotation = nil; spatialSelection = nil; spatialWorkspace = false }
        .task { homeStore.connect(); board.refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { homeStore.refreshPreview() }
        }
        .task(id: "\(board.homeID)|\(section ?? "")|\(scenePhase == .active)") {
            guard scenePhase == .active, section == "home", !board.homeID.isEmpty else { return }
            while !Task.isCancelled {
                await board.refreshPowerStates(automatic: true)
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
        .onReceive(homeStore.$lastUpdated) { _ in board.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .pdf]) { result in
            switch result { case .success(let url): board.importPlan(url); spatialWorkspace = true; case .failure(let e): board.error = e.localizedDescription }
        }
        .sheet(isPresented: $showingLayoutSettings) { LayoutSourceSettingsSheet(board: board) }
        .sheet(isPresented: $showingHomes) { HomeSelectionView(board: board, onSelect: { section = "home" }) }
        .sheet(item: $selectedDevice) { device in DeviceDetailView(board: board, deviceID: device.id) }
        .sheet(item: $sceneSheet) { item in SceneEditorView(board: board, scene: item.scene) }
        .sheet(item: $addingDevices) { session in
            DeviceSetupGuideView(board: board, homeStore: homeStore, session: session)
        }
        .confirmationDialog("执行场景“\(sceneToRun?.name ?? "")”？", isPresented: Binding(get: { sceneToRun != nil }, set: { if !$0 { sceneToRun = nil } }), titleVisibility: .visible) {
            Button("执行 \(sceneToRun?.actionCount ?? 0) 个动作") {
                guard let scene = sceneToRun else { return }; sceneToRun = nil
                Task { if await board.run(BoardCommand(tool: "execute_scene", arguments: ["scene_id": scene.id])) != nil { await board.refreshPowerStates() } }
            }
        } message: { Text("这会改变场景中设备的实际状态。") }
        .alert("删除场景？", isPresented: Binding(get: { sceneToDelete != nil }, set: { if !$0 { sceneToDelete = nil } })) {
            Button("删除", role: .destructive) { if let scene = sceneToDelete { Task { _ = await board.run(BoardCommand(tool: "delete_scene", arguments: ["scene_id": scene.id, "expected_name": scene.name])) } }; sceneToDelete = nil }
            Button("取消", role: .cancel) { sceneToDelete = nil }
        } message: { Text("将从 Apple 家庭中删除“\(sceneToDelete?.name ?? "")”，不会执行其中的设备动作。") }

    }
    private var dashboard: some View {
        HStack(spacing: 0) {
            if sidebarVisible { sidebar.frame(width: 228); Divider() }
            VStack(spacing: 0) {
                header
                Divider()
                if let error = board.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { board.error = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭错误提示")
                    }.buttonStyle(.plain).padding(14).background(.orange.opacity(0.1))
                }
                if section == "settings" { SettingsView(model: app, home: homeStore, board: board) }
                else if !homeStore.loaded {
                    VStack(spacing: 18) { ProgressView(); Text(homeStore.summary); Button("连接家庭") { homeStore.connect() } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if board.home == nil {
                    VStack(spacing: 12) { Image(systemName: "house").font(.largeTitle); Text("尚未找到家庭"); Text("请先在 Apple 家庭中建立或加入一个家庭。").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if section == "home" {
                    overview.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        if section == "scenes" { sceneGrid.padding(24) }
                        else { deviceGrid(section == "devices" ? board.devices : board.devices.filter { $0.roomId == section }).padding(24) }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("BrandIcon").resizable().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("栖间").font(.headline)
                    Text("家庭控制中心").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(22)
            #if targetEnvironment(macCatalyst)
            .padding(.top, 28)
            #endif
            Button { showingHomes = true } label: {
                HStack { Text(board.home?.name ?? "选择家庭").lineLimit(1); Spacer(minLength:4); Image(systemName:"chevron.down").font(.caption) }
                    .font(.callout).frame(maxWidth:.infinity,minHeight:36).padding(.horizontal,10)
                    .background(AppTheme.surface,in:RoundedRectangle(cornerRadius:8))
            }.buttonStyle(.plain).padding(.horizontal,12).padding(.bottom,12).accessibilityLabel("选择家庭")
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    sidebarLink("home", title: "家庭总览", icon: "square.grid.2x2.fill")
                    sidebarLink("devices", title: "所有设备", icon: "lightbulb.2.fill")
                    sidebarLink("scenes", title: "场景", icon: "sparkles")
                    Text("房间").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 24).padding(.horizontal, 12).padding(.bottom, 6)
                    ForEach(board.home?.rooms ?? []) { room in
                        sidebarLink(room.id, title: room.isDefault ? "未分配" : room.name, icon: roomIcon(room.name), count: room.accessoryCount)
                    }
                    Divider().padding(.vertical, 16)
                    sidebarLink("settings", title: "设置", icon: "gearshape")
                }.padding(.horizontal, 14).padding(.top, 8)
            }
            Label(homeStore.loaded ? "已连接 Apple 家庭" : "正在连接家庭", systemImage: homeStore.loaded ? "checkmark.circle.fill" : "clock")
                .font(.caption).foregroundStyle(homeStore.loaded ? boardAccent : .secondary).padding(20)
        }.background(AppTheme.sidebar)
    }
    private func sidebarLink(_ id: String, title: String, icon: String, count: Int? = nil) -> some View {
        Button { section = id } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).frame(width: 24)
                Text(title).font(.callout.weight(section == id ? .semibold : .regular))
                Spacer(minLength: 4)
                if let count { Text("\(count)").font(.caption.monospacedDigit()).opacity(0.7) }
            }.foregroundStyle(section == id ? Color.white : Color.primary)
                .padding(.horizontal, 12).frame(height: 46)
                .background(section == id ? AppTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(section == id ? .isSelected : [])
    }
    private var title: String {
        if section == "home" { return board.home?.name ?? "我的家" }
        if section == "devices" { return "所有设备" }
        if section == "scenes" { return "场景" }
        if section == "settings" { return "设置" }
        guard let room = board.home?.rooms.first(where: { $0.id == section }) else { return "房间" }
        return room.isDefault ? "未分配设备" : room.name
    }
    private var subtitle: String {
        if section == "home" { return "\(board.rooms.count) 个房间  ·  \(board.devices.count) 个设备  ·  \(board.scenes.count) 个场景" }
        if section == "scenes" { return "组合日常设备操作，轻松切换家的状态" }
        if section == "settings" { return "管理启动偏好、MCP 服务与家庭连接" }
        let devices = section == "devices" ? board.devices : board.devices.filter { $0.roomId == section }
        return "\(devices.count) 个设备  ·  \(devices.filter(\.reachable).count) 个可达"
    }
    private var header: some View {
        HStack(spacing: 14) {
            Button { sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left").font(.title3).frame(width: 36, height: 36)
            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(sidebarVisible ? "收起侧栏" : "展开侧栏")
            VStack(alignment: .leading, spacing: 4) {
                if section == "home" {
                    Button { showingHomes = true } label: {
                        HStack(spacing:8) { Text(title).font(.system(size:24,weight:.bold,design:.rounded)).lineLimit(1); Image(systemName:"chevron.down").font(.caption.weight(.semibold)) }
                    }.buttonStyle(.plain).accessibilityLabel("切换家庭，当前：" + title)
                } else { Text(title).font(.system(size:24,weight:.bold,design:.rounded)).lineLimit(1) }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if section != "settings" {
            Button { Task { await board.refreshPowerStates() } } label: {
                HStack(spacing:6) {
                    if board.refreshing { ProgressView().controlSize(.small); Text("刷新中…") }
                    else { Label("刷新",systemImage:"arrow.clockwise") }
                }
            }
                .buttonStyle(.bordered).disabled(!homeStore.loaded || board.refreshing || !board.reading.isEmpty).help("刷新设备状态")
            }
            if section == "home" {
                Button { spatialWorkspace = true } label: { Label("布置空间", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderedProminent).tint(AppTheme.selection).disabled(board.home == nil || !board.canEditLayout)
            }
            if section == "scenes" {
                Button { sceneSheet = SceneSheet(scene: nil) } label: { Label("新建场景", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(AppTheme.selection).disabled(board.home == nil || board.busy)
            }
            if section == "devices" {
                Button {
                    guard let home = board.home else { return }
                    addingDevices = DeviceSetupGuideSession(homeID: home.id, homeName: home.name,
                        existingIDs: Set(home.accessories.map(\.id)))
                } label: { Label("添加设备", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(AppTheme.selection).disabled(board.home == nil || !board.canEditLayout)
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
        #if targetEnvironment(macCatalyst)
        .padding(.leading, sidebarVisible ? 0 : 100)
        #endif
        .background(AppTheme.surface.opacity(0.96))
    }
    private var overview: some View {
        VStack(spacing: 14) {
            if board.planImage != nil || board.plan.spatial != nil {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        LayoutSourceMenu(board: board)
                        Spacer()
                        HStack(spacing: 10) {
                            Label { Text("开启") } icon: { Circle().fill(Color(DeviceAppearance(state: .on).fill)).overlay(Circle().stroke(Color(DeviceAppearance(state: .on).border), lineWidth: 1)).frame(width: 10, height: 10) }
                            Label { Text("关闭") } icon: { Circle().fill(AppTheme.surface).overlay(Circle().stroke(.gray, lineWidth: 1)).frame(width: 10, height: 10) }
                        }.font(.caption).foregroundStyle(.secondary)
                        if !showing3D { Toggle("底图", isOn: $planBackground).toggleStyle(.button).font(.callout) }
                        Picker("布局视图", selection: $layoutMode) { Text("2D").tag("2d"); Text("3D").tag("3d") }.pickerStyle(.segmented).frame(width: 140)
                        Button { showingCanvasHelp = true } label: { Image(systemName: "questionmark.circle").font(.title3) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("户型操作说明")
                            .popover(isPresented: $showingCanvasHelp) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("在户型图中控制设备").font(.headline)
                                    Text("单击简单开关直接切换；多功能设备打开控制面板。右键可以查看详情。")
                                    Text("2D 拖动平移，3D 拖动旋转视角；滚轮缩放。布局修改请进入“布置空间”。")
                                    Text("金色带“开”标记为开启；白色带“关”标记为关闭；沙漏表示处理中，问号表示待刷新，感叹号表示不可达。已开启的灯具会从摆放位置向所在房间投射暖色光晕。温湿度按设备当前读数自动刷新。")
                                }.font(.callout).padding(22).frame(width: 320)
                            }
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                    Divider()
                    GeometryReader { geometry in
                    Group {
                    if showing3D {
                        SpatialSceneView(board: board, editing: false, selected: spatialSelection, camera: $spatialCamera, labels: false, select: { spatialSelection = $0 }, open: { selectedDevice = $0 }, activate: activateDevice)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    } else {
                        PlanEditorView(board: board, editing: false, viewport: $planViewport, selected: spatialSelection, background: planBackground, snap: false, select: { spatialSelection = $0 }, open: { selectedDevice = $0 }, activate: activateDevice, displayQuarterTurns: planRotation)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    }
                    }.onAppear { overviewCanvasSize = geometry.size }
                        .onChange(of: geometry.size) { overviewCanvasSize = $0 }
                    }
                    Divider()
                    layoutSelectionControls.padding(.horizontal, 16).frame(height: 48)
                }.background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(boardAccent.opacity(0.08), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "square.split.2x2").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(boardAccent)
                    Text(board.cloud.isShared ? "选择家庭布局" : "让家的布局成为控制中心").font(.title2.bold())
                    Text(board.cloud.isShared ? "使用已授权的家庭布局，或切回自己的布局自由布置。" : "导入户型图，或创建空间，摆放房间和设备。\n支持图片、PDF，以及 AI 生成的布局 JSON。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    HStack {
                        if board.cloud.isShared {
                            Button("选择家庭布局") { showingLayoutSettings = true }.buttonStyle(.borderedProminent)
                        } else {
                            Button("导入户型图") { importing = true }.buttonStyle(.borderedProminent).tint(AppTheme.selection).disabled(!board.canEditLayout)
                            Button("创建空间") { spatialWorkspace = true }.buttonStyle(.bordered).disabled(!board.canEditLayout)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private func activateDevice(_ device: BoardDevice) {
        if device.supportsDirectPower {
            Task { await board.togglePower(device, refreshFirst: true) }
        } else { selectedDevice = device }
    }
    private var layoutSelectionControls: some View {
        HStack(spacing: 12) {
            if let device = board.devices.first(where: { "device:\($0.id)" == spatialSelection }) {
                Image(systemName: device.icon).font(.title3).foregroundStyle(boardAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.callout.bold()).lineLimit(1)
                    Text(board.sensorSummary(device).isEmpty ? device.roomName : board.sensorSummary(device)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                DeviceStatusBadge(state: board.visualState(device))
                if board.pendingPower.contains(device.id) { ProgressView().controlSize(.small) }
                if device.supportsDirectPower {
                    Button(board.isOn(device) == true ? "关闭" : board.isOn(device) == false ? "开启" : "读取并切换") {
                        activateDevice(device)
                    }.buttonStyle(.borderedProminent).tint(AppTheme.selection)
                        .disabled(board.busy || !board.pendingPower.isEmpty || !device.reachable)
                }
                Button("详情") { selectedDevice = device }.buttonStyle(.bordered)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("单击设备，直接操作").font(.callout.weight(.medium))
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Button { zoomCanvas(1/1.2) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 28, height: 28) }.accessibilityLabel("缩小视图")
                Text("\(Int((showing3D ? spatialCamera.zoom : planViewport.zoom)*100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42)
                Button { zoomCanvas(1.2) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 28, height: 28) }.accessibilityLabel("放大视图")
                Divider().frame(height: 18)
                if !showing3D {
                    Button {
                        let size = board.planImage?.size ?? CGSize(width: 1000, height: 800)
                        let projection = PlanProjection(imageWidth: size.width, imageHeight: size.height,
                            width: overviewCanvasSize.width, height: overviewCanvasSize.height,
                            points: board.plan.spatial?.rooms.flatMap(\.points) ?? [], state: PlanViewport(), quarterTurns: planRotation, padding: 32)
                        planRotation = (projection.quarterTurns + 1) % 4
                        planViewport = PlanViewport()
                    } label: { Image(systemName: "rotate.right").frame(width: 28, height: 28) }
                        .accessibilityLabel("户型顺时针旋转90度").help("旋转视图")
                }
                Button { if showing3D { spatialCamera = SpatialCamera() } else { planRotation = nil; planViewport = PlanViewport() } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 28)
                }.accessibilityLabel(showing3D ? "复位视角" : "适合窗口").help(showing3D ? "复位视角" : "适合窗口")
            }.buttonStyle(.plain).foregroundStyle(boardAccent)
        }
    }
    private func zoomCanvas(_ factor: Double) {
        if showing3D { spatialCamera.magnify(factor) }
        else { planViewport.zoom = min(6, max(0.35, planViewport.zoom * factor)) }
    }
    private func deviceGrid(_ devices: [BoardDevice]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if devices.isEmpty { Text("这个房间还没有设备。").foregroundStyle(.secondary).padding(30) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(devices) { device in DeviceCard(board: board, device: device) { selectedDevice = device } }
            }
        }
    }
    private var sceneGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 16)], spacing: 16) {
            ForEach(board.scenes) { scene in
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Image(systemName: scene.name.contains("睡") || scene.name.contains("晚") ? "moon.stars.fill" : "sparkles").font(.title2).foregroundStyle(boardAccent); Spacer(); Text("\(scene.actionCount) 个动作").font(.caption).foregroundStyle(.secondary) }
                    Text(scene.name).font(.headline)
                    HStack {
                        Button("编辑") { sceneSheet = SceneSheet(scene: scene) }.buttonStyle(.bordered)
                        Spacer()
                        Button { sceneToRun = scene } label: { Label("执行", systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(AppTheme.selection).disabled(board.busy || scene.actionCount == 0)
                    }
                }.padding(20).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                    .contextMenu { if scene.userDefined { Button("删除场景", role: .destructive) { sceneToDelete = scene } } }
            }
        }
    }
}

func roomIcon(_ name: String) -> String {
    if name.contains("卧") { return "bed.double.fill" }
    if name.contains("客") { return "sofa.fill" }
    if name.contains("厨") { return "fork.knife" }
    if name.contains("卫") { return "shower.fill" }
    return "square.grid.2x2"
}

struct DeviceCard: View {
    @ObservedObject var board: HomeBoardModel
    let device: BoardDevice
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button(action: open) { Image(systemName: device.icon).font(.title2).foregroundStyle(Color(DeviceAppearance(state: board.visualState(device)).ink)).frame(width: 44, height: 44).background(Color(DeviceAppearance(state: board.visualState(device)).fill), in: RoundedRectangle(cornerRadius: 13)) }.buttonStyle(.plain)
                Spacer()
                DeviceStatusBadge(state: board.visualState(device))
                if let power = device.power {
                    Button { Task { await board.togglePower(device) } } label: {
                        Image(systemName: board.reading.contains(power.id) ? "hourglass" : board.isOn(device) == nil ? "arrow.clockwise" : "power")
                            .frame(width: 36, height: 36).background(board.isOn(device) == true ? boardAccent.opacity(0.15) : Color.gray.opacity(0.08), in: Circle())
                    }.buttonStyle(.plain).foregroundStyle(boardAccent).disabled(board.busy || board.reading.contains(power.id) || !device.reachable)
                        .help(board.isOn(device) == nil ? "读取电源状态" : board.isOn(device) == true ? "关闭" : "开启")
                }
            }
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) { Text(device.name).font(.headline).foregroundStyle(.primary); Text("\(device.roomName) · \(board.status(device))").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }.padding(20).background(board.visualState(device) == .on ? AppTheme.onCard : AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(board.visualState(device) == .on ? Color(DeviceAppearance(state: .on).border).opacity(0.65) : Color.black.opacity(0.06), lineWidth: board.visualState(device) == .on ? 1.5 : 1))
    }
}

struct FloorPlanView: View {
    @ObservedObject var board: HomeBoardModel
    let editing: Bool
    let open: (BoardDevice) -> Void
    var body: some View {
        GeometryReader { geometry in
            if let image = board.planImage {
                let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let origin = CGPoint(x: (geometry.size.width - size.width) / 2, y: (geometry.size.height - size.height) / 2)
                ZStack(alignment: .topLeading) {
                    AppTheme.canvas
                    Image(uiImage: image).resizable().frame(width: size.width, height: size.height).position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
                    ForEach(board.rooms.filter { board.plan.rooms[$0.id] != nil }) { room in
                        if let p = board.plan.rooms[room.id] {
                            Text(room.name).font(.callout.bold()).padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule())
                                .position(x: origin.x + p.x * size.width, y: origin.y + p.y * size.height)
                                .gesture(drag(room.id, room: true, origin: origin, size: size), including: editing ? .all : .none)
                                .contextMenu { if editing { Button("移除标签") { board.unplace(room.id, room: true) } } }
                        }
                    }
                    ForEach(board.devices.filter { board.plan.devices[$0.id] != nil }) { device in
                        if let p = board.plan.devices[device.id] {
                            VStack(spacing: 4) {
                                HStack(spacing: 0) {
                                    Button { if !editing { open(device) } } label: { Image(systemName: device.icon).frame(width: 40, height: 38) }.buttonStyle(.plain)
                                    if !editing, device.power != nil {
                                        Button { Task { await board.togglePower(device) } } label: { Image(systemName: board.isOn(device) == nil ? "arrow.clockwise" : "power").frame(width: 30, height: 38) }.buttonStyle(.plain).disabled(board.busy || !device.reachable)
                                    }
                                }.foregroundStyle(board.isOn(device) == true ? .white : boardAccent).background(board.isOn(device) == true ? AppTheme.selection : AppTheme.surface, in: Capsule()).shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                                Text(device.name).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 3).background(.regularMaterial, in: Capsule())
                            }.position(x: origin.x + p.x * size.width, y: origin.y + p.y * size.height)
                                .gesture(drag(device.id, room: false, origin: origin, size: size), including: editing ? .all : .none)
                                .contextMenu { if editing { Button("从图中移除") { board.unplace(device.id, room: false) } } }
                        }
                    }
                }.coordinateSpace(name: "plan").clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    private func drag(_ id: String, room: Bool, origin: CGPoint, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("plan"))
            .onChanged { value in
                let point = PlanPoint(x: (value.location.x - origin.x) / max(1, size.width), y: (value.location.y - origin.y) / max(1, size.height))
                if room { board.plan.rooms[id] = point } else { board.plan.devices[id] = point }
            }
            .onEnded { value in board.place(id, room: room, at: PlanPoint(x: (value.location.x - origin.x) / max(1, size.width), y: (value.location.y - origin.y) / max(1, size.height))) }
    }
}
