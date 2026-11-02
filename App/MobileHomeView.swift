#if !targetEnvironment(macCatalyst)
import SwiftUI
import HomeKit
import UniformTypeIdentifiers

private let mobileAccent = Color(red: 0.15, green: 0.39, blue: 0.36)
private let mobileBackground = AppTheme.background

struct MobileHomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var home: HomeStore
    @StateObject private var board: HomeBoardModel
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0
    @State private var roomID = ""
    @State private var search = ""
    @State private var deviceSheet: BoardDevice?
    @State private var sceneSheet: SceneSheet?
    @State private var runningScene: BoardScene?
    @State private var deletingScene: BoardScene?
    @State private var showingLayout = false
    @State private var showingHomes = false
    @State private var homeLayoutMode = "2d"
    @State private var pairing = false
    @State private var pairingMessage = ""

    init(app: AppModel) {
        MobileChrome.configure()
        self.app = app; home = app.home
        _board = StateObject(wrappedValue: HomeBoardModel(app: app))
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                VStack(spacing: 8) {
                    connectionNotice
                    if board.home != nil {
                        MobileHomeLayoutCard(board: board, mode: $homeLayoutMode,
                            openDevice: { deviceSheet = $0 }, openFullScreen: { showingLayout = true })
                    } else { Spacer(minLength: 0) }
                }.padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(mobileBackground)
                    .navigationTitle("栖间").navigationBarTitleDisplayMode(.inline).toolbar { homeToolbar }
            }.modifier(MobileChrome()).tabItem { Label("家庭", systemImage: "house.fill") }.tag(0)

            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        connectionNotice
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                roomChip("全部", id: "")
                                ForEach(board.home?.rooms ?? []) { room in roomChip(room.isDefault ? "未分配" : room.name, id: room.id) }
                            }
                        }
                        if filteredDevices.isEmpty, board.home != nil {
                            empty("暂无设备", description: search.isEmpty ? "点右上角“＋”扫码添加配件。" : "试试其他设备名称或房间。", icon: "lightbulb")
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
                            ForEach(filteredDevices) { device in
                                MobileDeviceTile(board: board, device: device, open: { deviceSheet = device })
                            }
                        }
                    }.padding(18)
                }.background(mobileBackground).refreshable { await refresh() }
                    .searchable(text: $search, prompt: "搜索设备")
                    .navigationTitle("设备")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button { Task { await addAccessory() } } label: { Image(systemName: "plus") }
                                .accessibilityLabel("扫码添加设备").disabled(pairing || board.home == nil)
                        }
                    }
            }.modifier(MobileChrome()).tabItem { Label("设备", systemImage: "lightbulb.2.fill") }.tag(1)

            NavigationStack {
                ScrollView {
                    VStack(spacing: 14) {
                        connectionNotice
                        if board.scenes.isEmpty { empty("创建你的第一个场景", description: "把多个设备操作组合成“准备睡觉”等日常场景。", icon: "sparkles") }
                        ForEach(board.scenes) { scene in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Image(systemName: scene.name.contains("睡") ? "moon.stars.fill" : "sparkles").font(.title2).foregroundStyle(mobileAccent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(scene.name).font(.headline)
                                        Text("\(scene.actionCount) 个动作").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Menu {
                                        Button("编辑场景") { sceneSheet = SceneSheet(scene: scene) }
                                        if scene.userDefined { Button("删除场景", role: .destructive) { deletingScene = scene } }
                                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("管理\(scene.name)")
                                }
                                Button { runningScene = scene } label: { Label("执行场景", systemImage: "play.fill").frame(maxWidth: .infinity) }
                                    .buttonStyle(.bordered).disabled(board.busy || scene.actionCount == 0)
                            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 18))
                        }
                    }.padding(18)
                }.background(mobileBackground).navigationTitle("场景")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button { sceneSheet = SceneSheet(scene: nil) } label: { Image(systemName: "plus") }
                                .accessibilityLabel("新建场景").disabled(board.home == nil || board.busy)
                        }
                    }
                    .refreshable { home.refreshPreview() }
            }.modifier(MobileChrome()).tabItem { Label("场景", systemImage: "sparkles") }.tag(2)

            NavigationStack {
                List {
                    Section("Apple 家庭") {
                        LabeledContent("连接状态", value: home.authorization == "authorized" && home.loaded ? "已连接" : "等待授权或连接")
                        Button { showingHomes = true } label: {
                            HStack { Text("当前家庭"); Spacer(); Text(board.home?.name ?? "选择家庭").foregroundStyle(.secondary); Image(systemName:"chevron.right").font(.caption) }
                        }
                        Button("刷新家庭连接") { home.connect() }
                        Button("扫码添加设备") { Task { await addAccessory() } }.disabled(pairing || board.home == nil)
                    }
                    Section {
                        Button("户型图与布局") { showingLayout = true }.disabled(board.home == nil)
                    } footer: { Text("设备与场景由 Apple 家庭同步。户型可导入图片、PDF 或空间布局 JSON，也可启用下方 iCloud 同步与共享。") }
                    Section { CloudLayoutSettingsView(board: board) }
                    Section("权限") {
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        Text("首次使用需允许访问家庭。手机端直接连接 HomeKit，无需连接 Mac 的 MCP 服务。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("关于") {
                        LabeledContent("栖间", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                        Text("iPhone · iPad").foregroundStyle(.secondary)
                    }
                }.scrollContentBackground(.hidden).background(mobileBackground).navigationTitle("设置")
            }.modifier(MobileChrome()).tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(3)
        }.background(mobileBackground.ignoresSafeArea()).tint(mobileAccent).preferredColorScheme(.light)
            .modifier(CloudLayoutLifecycle(board: board))
            .task { home.connect(); board.refresh() }
            .onReceive(home.$lastUpdated) { _ in board.refresh() }
            .onChange(of: board.homeID) { _ in roomID = ""; search = ""; deviceSheet = nil; sceneSheet = nil; runningScene = nil; deletingScene = nil; showingLayout = false }
            .onChange(of: phase) { if $0 == .active { home.refreshPreview() } }
            .task(id: "\(board.homeID)|\(tab)|\(phase == .active)") {
                guard phase == .active, tab < 2, !board.homeID.isEmpty else { return }
                while !Task.isCancelled {
                    await board.refreshPowerStates(automatic: true)
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                }
            }
            .sheet(isPresented: $showingHomes) { HomeSelectionView(board: board, onSelect: { tab = 0 }) }
            .sheet(item: $deviceSheet) { DeviceDetailView(board: board, deviceID: $0.id).tint(mobileAccent) }
            .sheet(item: $sceneSheet) { SceneEditorView(board: board, scene: $0.scene).tint(mobileAccent) }
            .fullScreenCover(isPresented: $showingLayout) { MobileLayoutView(board: board, initialMode: homeLayoutMode).tint(mobileAccent) }
            .alert("操作未完成", isPresented: Binding(get: { board.error != nil }, set: { if !$0 { board.error = nil } })) {
                Button("知道了") { board.error = nil }
            } message: { Text(board.error ?? "") }
            .alert("添加设备", isPresented: Binding(get: { !pairingMessage.isEmpty }, set: { if !$0 { pairingMessage = "" } })) {
                Button("完成") { pairingMessage = "" }
            } message: { Text(pairingMessage) }
            .confirmationDialog("执行“\(runningScene?.name ?? "")”？", isPresented: Binding(get: { runningScene != nil }, set: { if !$0 { runningScene = nil } }), titleVisibility: .visible) {
                Button("执行场景") {
                    guard let scene = runningScene else { return }; runningScene = nil
                    Task { _ = await board.run(BoardCommand(tool: "execute_scene", arguments: ["scene_id": scene.id])); await board.refreshPowerStates() }
                }
            } message: { Text("这会改变场景中设备的实际状态。") }
            .confirmationDialog("删除场景？", isPresented: Binding(get: { deletingScene != nil }, set: { if !$0 { deletingScene = nil } }), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let scene = deletingScene else { return }; deletingScene = nil
                    Task { _ = await board.run(BoardCommand(tool: "delete_scene", arguments: ["scene_id": scene.id, "expected_name": scene.name])) }
                }
            } message: { Text("将从 Apple 家庭中删除场景，其他设备也会同步此更改。") }
    }

    private var filteredDevices: [BoardDevice] {
        board.devices.filter { (roomID.isEmpty || $0.roomId == roomID) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }
    @ViewBuilder private var connectionNotice: some View {
        if !home.loaded || board.home == nil {
            VStack(spacing: 14) {
                Image(systemName: "house.badge.exclamationmark").font(.largeTitle).foregroundStyle(mobileAccent)
                Text(home.authorization == "denied" ? "需要家庭访问权限" : home.loaded ? "尚未找到家庭" : "正在连接你的家庭").font(.headline)
                Text(home.authorization == "denied" ? "请在系统设置中允许“栖间”访问家庭。" : "请使用已加入 Apple 家庭的账号，并保持网络连接。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重新检查") { home.connect() }.buttonStyle(.bordered)
            }.frame(maxWidth: .infinity).padding(24).background(.white, in: RoundedRectangle(cornerRadius: 18))
        }
        #if targetEnvironment(simulator) && DEBUG
        if home.isDemo { Label("演示家庭 · 不控制真实设备", systemImage: "testtube.2").font(.caption).foregroundStyle(.orange) }
        #endif
    }
    @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button { showingHomes = true } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Text(board.home?.name ?? "选择家庭").font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    if board.home != nil {
                        Text("\(board.rooms.count) 个房间 · \(board.devices.count) 个设备")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.foregroundStyle(.primary)
            }.buttonStyle(.plain).accessibilityLabel("切换家庭，当前：" + (board.home?.name ?? "尚未选择"))
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Button { Task { await refresh() } } label: {
                if board.refreshing { ProgressView() }
                else { Image(systemName: "arrow.clockwise") }
            }.accessibilityLabel("刷新设备状态").disabled(board.refreshing || !home.loaded)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button("选择家庭") { showingHomes = true }
                Button("添加设备") { Task { await addAccessory() } }.disabled(pairing || board.home == nil)
            } label: { Image(systemName: "plus.circle") }.accessibilityLabel("家庭与设备")
        }
    }
    private func roomChip(_ title: String, id: String) -> some View {
        Button { roomID = id } label: {
            Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                .foregroundStyle(roomID == id ? .white : mobileAccent)
                .background(roomID == id ? mobileAccent : .white, in: Capsule())
        }.buttonStyle(.plain)
    }
    private func empty(_ title: String, description: String, icon: String) -> some View {
        VStack(spacing: 12) { Image(systemName: icon).font(.largeTitle); Text(title).font(.headline); Text(description).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            .frame(maxWidth: .infinity).padding(32)
    }
    private func refresh() async { home.refreshPreview(); await board.refreshPowerStates() }
    private func addAccessory() async {
        guard !pairing, let id = UUID(uuidString: board.homeID) else { return }
        #if targetEnvironment(simulator)
        pairingMessage = "请在真实 iPhone 或 iPad 上扫码添加设备，模拟器不能完成实际配对。"
        #else
        if #available(iOS 27.0, *), !HMAccessorySetupManager.isSupported {
            pairingMessage = "此设备暂不支持应用内配对，请使用 Apple 家庭添加配件；添加后会自动同步。"; return
        }
        pairing = true; defer { pairing = false; home.refreshPreview() }
        let request = HMAccessorySetupRequest(); request.homeUniqueIdentifier = id
        do {
            _ = try await HMAccessorySetupManager().performAccessorySetup(using: request)
            pairingMessage = "配对流程已完成，新设备会同步到设备列表和对应房间。"
        } catch {
            let failure = error as NSError
            if failure.domain == HMErrorDomain && failure.code == HMError.Code.operationCancelled.rawValue { return }
            pairingMessage = "未能完成配对：\(error.localizedDescription)"
        }
        #endif
    }
}

private struct MobileDeviceTile: View {
    @ObservedObject var board: HomeBoardModel
    let device: BoardDevice
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: open) { Image(systemName: device.icon).font(.title2).frame(width: 44, height: 44) }.buttonStyle(.plain)
                Spacer(minLength: 0)
                if device.power != nil {
                    Button { Task { await board.togglePower(device, refreshFirst: device.supportsDirectPower) } } label: {
                        if board.pendingPower.contains(device.id) { ProgressView().frame(width: 44, height: 44) }
                        else { Image(systemName: board.isOn(device) == nil ? "arrow.clockwise" : "power").frame(width: 44, height: 44) }
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .disabled(board.busy || !device.reachable || !board.pendingPower.isEmpty)
                        .accessibilityLabel("\(device.name)：\(board.isOn(device) == nil ? "读取状态" : board.isOn(device) == true ? "关闭" : "开启")")
                }
            }
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name).font(.headline).lineLimit(2).frame(minHeight: 38, alignment: .topLeading)
                    Text(board.status(device)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(device.roomName).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(14).foregroundStyle(mobileAccent)
            .background(board.isOn(device) == true ? Color(red: 1, green: 0.94, blue: 0.76) : .white, in: RoundedRectangle(cornerRadius: 20))
    }
}
#endif
