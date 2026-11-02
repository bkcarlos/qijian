#if !targetEnvironment(macCatalyst)
import SwiftUI

/// Inline control surface: canvas gestures navigate the view, never edit the saved layout.
struct MobileHomeLayoutCard: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var board: HomeBoardModel
    @Binding var mode: String
    let openDevice: (BoardDevice) -> Void
    let openFullScreen: () -> Void
    @State private var rotationOverride: Int?
    @State private var viewport = PlanViewport()
    @State private var camera: SpatialCamera = {
        var camera = SpatialCamera(); camera.zoom = 1.5; return camera
    }()
    @State private var selected: String?
    @State private var showingLayoutSettings = false
    @State private var showingHelp = false
    @State private var canvasSize = CGSize(width: 1, height: 1)
    private var hasLayout: Bool { board.plan.spatial != nil || board.planImage != nil }
    private var fit: PlanProjection {
        let image = board.planImage?.size ?? CGSize(width:1000,height:800)
        return PlanProjection(imageWidth:image.width,imageHeight:image.height,width:max(1,canvasSize.width),height:max(1,canvasSize.height),
            points:board.plan.spatial?.rooms.flatMap(\.points) ?? [],state:PlanViewport(),quarterTurns:rotationOverride,padding:18)
    }
    var body: some View {
        Group {
        if verticalSizeClass == .compact && hasLayout {
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    LayoutSourceMenu(board: board)
                    Picker("首页布局视图", selection: $mode) {
                        Text("2D").tag("2d"); Text("3D").tag("3d")
                    }.pickerStyle(.segmented)
                    HStack(spacing: 4) {
                        if mode == "2d" {
                            Button { rotationOverride = (fit.quarterTurns + 1) % 4; viewport = PlanViewport() } label: {
                                Image(systemName: "rotate.right").frame(width: 44, height: 44)
                            }.accessibilityLabel("户型顺时针旋转90度")
                        }
                        Button {
                            rotationOverride = nil; viewport = PlanViewport(); camera = SpatialCamera(); camera.zoom = 1.5
                        } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass").frame(width: 44, height: 44) }
                            .accessibilityLabel("自适应视图")
                    }
                    Button(action: openFullScreen) {
                        Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right").font(.caption).frame(minHeight: 44)
                    }.accessibilityLabel("全屏查看布局")
                }.frame(width: 112).padding(.horizontal, 8)
                canvas
            }
        } else {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LayoutSourceMenu(board: board)
                Spacer(minLength: 0)
                if hasLayout {
                    Picker("首页布局视图", selection: $mode) {
                        Text("2D").tag("2d")
                        Text("3D").tag("3d")
                    }.pickerStyle(.segmented).frame(width: 108)
                }
                Button(action: openFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                }.accessibilityLabel("全屏查看布局")
            }.padding(.leading, 16).padding(.trailing, 6)
            if hasLayout {
                canvas
                HStack {
                    Button { showingHelp = true } label: {
                        Image(systemName: board.cloud.isShared ? "lock.circle" : "questionmark.circle").frame(width: 44, height: 44)
                    }.accessibilityLabel("户型操作说明")
                    Spacer(minLength: 0)
                    Text("轻点设备控制").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer()
                    if mode == "2d" {
                        Button { rotationOverride = (fit.quarterTurns+1)%4; viewport = PlanViewport() } label: {
                            Label("旋转",systemImage:"rotate.right").font(.caption).frame(minHeight:44)
                        }.accessibilityLabel("户型顺时针旋转90度")
                        Button("自适应") { rotationOverride = nil; viewport = PlanViewport() }.font(.caption).frame(minHeight:44)
                    } else { Button("复位") { camera = SpatialCamera(); camera.zoom = 1.5 }.font(.caption).frame(minHeight:44) }
                }.padding(.leading, 2).padding(.trailing, 14)
                    .alert("在户型图中控制设备", isPresented: $showingHelp) {
                        Button("知道了", role: .cancel) {}
                    } message: {
                        Text("2D 拖动平移、双指缩放；3D 单指旋转、双指缩放或平移。轻点简单开关直接切换，多功能设备打开面板。黄色表示开启。" + (board.cloud.isShared ? "家庭布局只读，设备控制遵循 Apple 家庭权限。" : "修改布局请进入全屏的布置空间。"))
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.split.2x2").font(.largeTitle).foregroundStyle(.teal)
                    Text(board.cloud.isShared ? "选择已授权的家庭布局" : "无需邀请，导入或创建自己的户型").font(.subheadline).foregroundStyle(.secondary)
                    if board.cloud.isShared {
                        Button("选择家庭布局") { showingLayoutSettings = true }.buttonStyle(.bordered)
                    } else { Button("添加户型", action: openFullScreen).buttonStyle(.bordered) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            }
        }
        }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: board.homeID) { _ in mode = "2d"; rotationOverride = nil; selected = nil; viewport = PlanViewport(); camera = SpatialCamera(); camera.zoom = 1.5 }
            .onChange(of: board.layoutSource) { _ in mode = "2d"; rotationOverride = nil; selected = nil; viewport = PlanViewport(); camera = SpatialCamera(); camera.zoom = 1.5 }
            .sheet(isPresented: $showingLayoutSettings) { LayoutSourceSettingsSheet(board: board) }
    }
    private var canvas: some View {
        GeometryReader { geometry in
                Group {
                    if mode == "3d" {
                        SpatialSceneView(board: board, editing: false, selected: selected, camera: $camera, labels: false,
                            select: { selected = $0 }, open: openDevice, activate: activate, embedded: true)
                    } else {
                        PlanEditorView(board: board, editing: false, viewport: $viewport, selected: selected, background: false, snap: false,
                            select: { selected = $0 }, open: openDevice, activate: activate, embedded: true, displayQuarterTurns: rotationOverride)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .onAppear { canvasSize = geometry.size }
                    .onChange(of: geometry.size) { size in canvasSize = size; viewport = PlanViewport() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func activate(_ device: BoardDevice) {
        if device.supportsDirectPower { Task { await board.togglePower(device, refreshFirst: true) } }
        else { openDevice(device) }
    }
}
#endif
