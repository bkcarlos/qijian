#if !targetEnvironment(macCatalyst)
import SwiftUI
import UniformTypeIdentifiers

struct MobileLayoutView: View {
    @ObservedObject var board: HomeBoardModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "2d"
    @State private var editing = false
    @State private var selected: String?
    @State private var viewport = PlanViewport()
    @State private var camera = SpatialCamera()
    @State private var deviceSheet: BoardDevice?
    @State private var importing = false
    @State private var imageImport = false
    @State private var review: LayoutImportReview?
    private var hasLayout: Bool { board.planImage != nil || board.plan.spatial != nil }

    init(board: HomeBoardModel, initialMode: String = "2d") {
        self.board = board
        _mode = State(initialValue: initialMode)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if hasLayout {
                    Picker("视图", selection: $mode) { Text("2D 布局").tag("2d"); Text("3D 空间").tag("3d") }
                        .pickerStyle(.segmented).padding(.horizontal).disabled(editing)
                    if mode == "2d" {
                        // Separate identities keep the editing and control gesture sets distinct.
                        PlanEditorView(board: board, editing: editing && board.canEditLayout, viewport: $viewport, selected: selected, background: true, snap: editing,
                            select: { selected = $0 }, open: { deviceSheet = $0 }, activate: activate)
                            .id(editing).clipped()
                    } else {
                        SpatialSceneView(board: board, editing: false, selected: selected, camera: $camera, labels: false,
                            select: { selected = $0 }, open: { deviceSheet = $0 }, activate: activate).clipped()
                    }
                    controls.padding(.horizontal)
                    Text(board.cloud.isShared ? "共享布局只读；设备仍按你的 Apple 家庭权限控制。" : (editing ? "拖动组件调整位置；选中房间可调整角点。" : "轻点设备操作；双指缩放，拖动平移或旋转视角。"))
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    if editing {
                        HStack {
                            Menu("放置设备") {
                                ForEach(board.devices) { device in
                                    Button(device.name) { board.checkpointLayout(); board.place(device.id, room: false); selected = "device:\(device.id)" }
                                }
                            }
                            Spacer()
                            Button("撤销") { board.undoLayout() }.disabled(board.layoutUndo.isEmpty)
                        }.padding(.horizontal)
                    }
                } else {
                    Spacer()
                    Image(systemName: "square.split.2x2").font(.system(size: 60, weight: .light)).foregroundStyle(.teal)
                    Text("把家的布局带到手机").font(.title2.bold())
                    Text("导入户型图或空间布局 JSON，在图上查看和控制设备。可在设置中启用 iCloud 布局同步。")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                    Button("导入空间布局 JSON") { imageImport = false; importing = true }.disabled(!board.canEditLayout).buttonStyle(.borderedProminent)
                    Button("导入图片或 PDF") { imageImport = true; importing = true }.disabled(!board.canEditLayout).buttonStyle(.bordered)
                    Spacer()
                }
            }.padding(.bottom, 12).background(Color(red: 0.96, green: 0.96, blue: 0.94))
                .navigationTitle(editing ? "布置空间" : "家的布局").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            if hasLayout {
                                Button(editing ? "结束布置" : "布置空间") { mode = "2d"; editing.toggle() }.disabled(!board.canEditLayout)
                                Button("适合窗口") { viewport = PlanViewport(); camera = SpatialCamera() }
                            }
                            Button("导入空间布局 JSON") { imageImport = false; importing = true }.disabled(!board.canEditLayout)
                            Button("导入图片或 PDF") { imageImport = true; importing = true }.disabled(!board.canEditLayout)
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("布局选项")
                    }
                }
        }
        .onChange(of: editing) { board.layoutEditing = $0 }
        .onChange(of: board.cloud.isShared) { if $0 { editing = false } }
        .onDisappear { board.layoutEditing = false }
        .fileImporter(isPresented: $importing, allowedContentTypes: imageImport ? [.image, .pdf] : [.json]) { result in
            switch result {
            case .success(let url):
                if imageImport { board.importPlan(url) } else { review = board.prepareCalibration(url) }
            case .failure(let error): board.error = error.localizedDescription
            }
        }
        .sheet(item: $review) { item in
            LayoutImportReviewView(board: board, review: item) { if board.applyCalibration(item) { review = nil } }
        }
        .sheet(item: $deviceSheet) { DeviceDetailView(board: board, deviceID: $0.id) }
        .alert("操作未完成", isPresented: Binding(get: { board.error != nil }, set: { if !$0 { board.error = nil } })) {
            Button("知道了") { board.error = nil }
        } message: { Text(board.error ?? "") }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if let device = board.devices.first(where: { "device:\($0.id)" == selected }) {
                Button { deviceSheet = device } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).font(.subheadline.bold()).lineLimit(1)
                        Text(board.status(device)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.buttonStyle(.plain)
            } else { Text(editing ? "选择组件进行调整" : "轻点设备，直接操作").font(.subheadline) }
            Spacer(minLength: 4)
            Button { zoom(1/1.2) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("缩小布局")
            Button { zoom(1.2) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("放大布局")
        }
    }
    private func zoom(_ factor: Double) {
        if mode == "2d" { viewport.zoom = min(6, max(0.35, viewport.zoom * factor)) }
        else { camera.magnify(factor) }
    }
    private func activate(_ device: BoardDevice) {
        if device.supportsDirectPower { Task { await board.togglePower(device, refreshFirst: true) } }
        else { deviceSheet = device }
    }
}
#endif
