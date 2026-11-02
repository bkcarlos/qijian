import SwiftUI
import UniformTypeIdentifiers

private let spaceAccent = AppTheme.accent

struct SpatialWorkspace: View {
    @ObservedObject var board: HomeBoardModel
    let onClose: () -> Void
    @State private var mode: String
    @State private var viewport = PlanViewport()
    @State private var showBackground = false
    @AppStorage("homeBoard.layoutSnap") private var snap = true
    init(board: HomeBoardModel, initialMode: String = "2d", onClose: @escaping () -> Void) {
        self.board = board; self.onClose = onClose; _mode = State(initialValue: initialMode)
    }
    @State private var category = "devices"
    @State private var selected: String?
    @State private var camera = SpatialCamera()
    @State private var labels = false
    @State private var drawingRoom: BoardRoom?
    @State private var draft: [PlanPoint] = []
    @State private var importing = false
    @State private var importingPlan = false
    @State private var showingJSONGuide = false
    @State private var layoutImport: LayoutImportReview?
    @State private var removingPlan = false
    @State private var deviceSheet: BoardDevice?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) { Text("布置我的家").font(.title2.bold()); Text("墙体 · 家具 · 智能设备").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Picker("视图", selection: $mode) { Text("2D 布局").tag("2d"); Text("3D 俯视").tag("3d"); Text("描摹户型").tag("trace") }.pickerStyle(.segmented).frame(width: 290)
                Button { board.undoLayout() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }.disabled(board.layoutUndo.isEmpty)
                Menu("JSON 布局") {
                    Button("导入空间布局 JSON") { importingPlan = false; importing = true }
                    Button("AI 布局规则与提示词") { showingJSONGuide = true }
                }
                Menu {
                    Button(board.planImage == nil ? "导入户型图" : "替换户型图") { importingPlan = true; importing = true }
                    if board.planImage != nil || board.plan.spatial != nil { Button("移除户型图", role: .destructive) { removingPlan = true } }
                } label: { Image(systemName: "ellipsis.circle") }
                Button("完成", action: onClose).buttonStyle(.borderedProminent).tint(AppTheme.selection)
            }.padding(20)
            #if targetEnvironment(macCatalyst)
            .padding(.leading, 100)
            #endif
            if let error = board.error { HStack { Text(error).font(.caption); Spacer(); Button("关闭提示") { board.error = nil } }.padding(12).background(.orange.opacity(0.12)) }
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("组件库", selection: $category) { Text("设备").tag("devices"); Text("家具").tag("furniture"); Text("房间").tag("rooms") }.pickerStyle(.segmented)
                    Text(category == "devices" ? "拖入画布，或点 ＋ 放入选中房间" : category == "furniture" ? "拖入家具后，可调整方向和尺寸" : "在底图上沿内墙点击，建立房间轮廓").font(.caption).foregroundStyle(.secondary)
                    if category == "furniture" {
                        FurnitureCatalogView(addBasic: { selected = board.addFurniture($0,at:insertionPoint) }, addModel: { selected = board.addModel($0,at:insertionPoint) })
                    } else {
                        ScrollView {
                            VStack(alignment:.leading,spacing:10) {
                                if category == "devices" { deviceLibrary } else { roomLibrary }
                            }
                        }
                    }
                    Divider()
                    inspector
                }.padding(16).frame(width: 255).background(AppTheme.raised)
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        if mode == "3d" {
                            Button { camera.yaw -= 30 } label: { Label("向左旋转", systemImage: "rotate.left") }
                            Button { camera.yaw += 30 } label: { Label("向右旋转", systemImage: "rotate.right") }
                            Button { camera.magnify(1/1.2) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("缩小")
                            Button { camera.magnify(1.2) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("放大")
                            Text("\(Int(camera.zoom*100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button("复位") { camera = SpatialCamera() }
                            Spacer(); Toggle("设备名称", isOn: $labels).toggleStyle(.button)
                        } else if mode == "2d" {
                            Toggle("底图", isOn: $showBackground).toggleStyle(.button)
                            Toggle("自动吸附", isOn: $snap).toggleStyle(.button)
                            Spacer()
                            Button { viewport.zoom = max(0.35,viewport.zoom/1.2) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("缩小平面图")
                            Text("\(Int(viewport.zoom*100))%").font(.caption.monospacedDigit())
                            Button { viewport.zoom = min(6,viewport.zoom*1.2) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("放大平面图")
                            Button("适合窗口") { viewport = PlanViewport() }
                        } else if let room = drawingRoom {
                            Toggle("自动吸附", isOn: $snap).toggleStyle(.button)
                            Text("描摹：\(room.name) · \(draft.count) 个点").font(.callout.bold())
                            Spacer(); Button("退一步") { if !draft.isEmpty { draft.removeLast() } }.disabled(draft.isEmpty)
                            Button("取消") { drawingRoom = nil; draft = [] }
                            Button("闭合并生成墙体") { finishRoom(room) }.buttonStyle(.borderedProminent).tint(AppTheme.selection).disabled(draft.count < 3)
                        } else {
                            Toggle("自动吸附", isOn: $snap).toggleStyle(.button)
                            Text("描摹时点击起点闭合；右键墙边加点、角点删除。").font(.caption); Spacer()
                        }
                    }.padding(12).buttonStyle(.bordered)
                    Group {
                    if mode == "3d" {
                        SpatialSceneView(board: board, editing: true, selected: selected, camera: $camera, labels: labels, select: { selected = $0 }, open: { deviceSheet = $0 })
                            .overlay(alignment: .bottomLeading) {
                                if board.plan.spatial?.rooms.isEmpty != false { Text("还没有墙体：切换到“描摹户型”，建立房间轮廓。").font(.callout).padding(12).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 12)).padding() }
                            }
                    } else if mode == "2d" {
                        PlanEditorView(board: board, editing: true, viewport: $viewport, selected: selected, background: showBackground, snap: snap, select: { selected = $0 }, open: { deviceSheet = $0 })
                    } else {
                        SpatialTraceView(board: board, selected: $selected, draft: $draft, drawing: drawingRoom != nil, snap: snap, drawingRoomID: drawingRoom?.id) {
                            if let room = drawingRoom { finishRoom(room) }
                        }
                    }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    HStack { Image(systemName: "checkmark.circle"); Text(mode == "2d" ? "自动吸附角点 / 墙边 / 对齐线 · 右键墙边加点 / 角点删除 · 滚轮缩放" : mode == "trace" ? "点击描摹 · 满三个点后点击起点闭合 · 自动吸附可关闭 · 右键墙边加点 / 角点删除" : "拖组件移动 · 拖空白旋转 · Shift 拖动平移 · 滚轮缩放 · 右键编辑 · 双击设备控制"); Spacer() }.font(.caption).foregroundStyle(.secondary).padding(12)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.background).tint(spaceAccent)
        .confirmationDialog("移除户型图和布局？", isPresented: $removingPlan, titleVisibility: .visible) {
            Button("移除户型图", role: .destructive) { board.removePlan(); selected = nil; draft = []; drawingRoom = nil; viewport = PlanViewport(); camera = SpatialCamera() }
        } message: { Text("只移除本 App 的显示与标记，原始文件和 Apple 家庭设备不会改变。本地副本会保留在应用目录。") }
        .sheet(isPresented: $showingJSONGuide) { LayoutJSONGuideView(context: board.layoutGenerationContext) }
        .sheet(item: $layoutImport) { review in
            LayoutImportReviewView(board: board, review: review) {
                if board.applyCalibration(review) {
                    selected = nil; drawingRoom = nil; draft = []; viewport = PlanViewport(); camera = SpatialCamera(); mode = "2d"
                    layoutImport = nil
                }
            }
        }
        .sheet(item: $deviceSheet) { DeviceDetailView(board: board, deviceID: $0.id) }
        .onAppear { board.layoutEditing = true }
        .onDisappear { board.layoutEditing = false }
        .fileImporter(isPresented: $importing, allowedContentTypes: importingPlan ? [.image, .pdf] : [.json]) { result in
            switch result {
            case .success(let url):
                if importingPlan { board.importPlan(url); selected = nil; draft = []; drawingRoom = nil; viewport = PlanViewport() }
                else { layoutImport = board.prepareCalibration(url) }
                mode = "2d"
            case .failure(let error): board.error = error.localizedDescription
            }
        }
    }
    var insertionPoint: PlanPoint {
        if let room = board.plan.spatial?.rooms.first(where: { "room:\($0.id)" == selected }) { return room.center }
        return board.plan.spatial?.rooms.first?.center ?? PlanPoint(x: 0.5, y: 0.5)
    }
    var deviceLibrary: some View {
        ForEach(board.home?.rooms ?? []) { room in
            Text(room.name).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(board.devices.filter { $0.roomId == room.id }) { device in
                HStack {
                    Button { selected = "device:\(device.id)" } label: { Label(device.name, systemImage: device.icon).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                    if board.plan.devices[device.id] == nil {
                        Button { board.checkpointLayout(); board.place(device.id, room: false, at: board.plan.spatial?.rooms.first(where: { $0.id == device.roomId })?.center ?? insertionPoint); selected = "device:\(device.id)" } label: { Image(systemName: "plus.circle.fill") }.accessibilityLabel("放入\(device.name)")
                    } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(spaceAccent) }
                }.padding(10).background(selected == "device:\(device.id)" ? spaceAccent.opacity(0.13) : AppTheme.surface,in: RoundedRectangle(cornerRadius: 10))
                    .onDrag { NSItemProvider(object: "home-device:\(device.id)" as NSString) }
            }
        }
    }
    var furnitureLibrary: some View {
        ForEach(SpatialFurniture.kinds,id: \.self) { kind in
            Button { selected = board.addFurniture(kind, at: insertionPoint) } label: {
                HStack { Label(SpatialFurniture.title(kind), systemImage: SpatialFurniture.icon(kind)); Spacer(); Image(systemName: "plus") }.padding(14).background(AppTheme.surface,in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).onDrag { NSItemProvider(object: "home-furniture:\(kind)" as NSString) }
        }
    }
    var roomLibrary: some View {
        ForEach(board.rooms) { room in
            HStack {
                Button { selected = "room:\(room.id)" } label: { Text(room.name).frame(maxWidth:.infinity, alignment: .leading) }.buttonStyle(.plain)
                Button { mode = "trace"; drawingRoom = room; draft = []; selected = "room:\(room.id)" } label: { Image(systemName: "pencil.and.outline") }.accessibilityLabel("描摹\(room.name)")
            }.padding(12).background(selected == "room:\(room.id)" ? spaceAccent.opacity(0.13) : AppTheme.surface,in: RoundedRectangle(cornerRadius: 10))
        }
    }
    @ViewBuilder var inspector: some View {
        if let selected, selected.hasPrefix("device:"), let device = board.devices.first(where: { "device:\($0.id)" == selected }) {
            Text(device.name).font(.headline)
            Text("\(device.roomName) · \(board.status(device))").font(.caption).foregroundStyle(.secondary)
            Button("打开设备控制") { deviceSheet = device }.buttonStyle(.borderedProminent).tint(AppTheme.selection)
            if board.plan.devices[device.id] != nil { Button("移出画布", role: .destructive) { board.checkpointLayout(); board.unplace(device.id,room:false) } }
        } else if let selected, let index = board.plan.spatial?.furniture.firstIndex(where: { "furniture:\($0.id)" == selected }), let f = board.plan.spatial?.furniture[index] {
            Text(FurnitureLibrary.shared.title(f)).font(.headline)
            HStack {
                Button("旋转 90°") { board.checkpointLayout(); board.plan.spatial?.furniture[index].rotation = (f.rotation+90).truncatingRemainder(dividingBy: 360); board.saveLayout() }
                Button("移除",role:.destructive) { board.checkpointLayout(); board.plan.spatial?.furniture.remove(at:index); self.selected = nil; board.saveLayout() }
            }
            Stepper("宽度 \(Int(f.width*100))%", onIncrement: { resize(index, width: true, delta: 0.01) }, onDecrement: { resize(index,width:true,delta:-0.01) })
            Stepper("深度 \(Int(f.depth*100))%", onIncrement: { resize(index,width:false,delta:0.01) }, onDecrement: { resize(index,width:false,delta:-0.01) })
        } else if let selected, let index = board.plan.spatial?.rooms.firstIndex(where: { "room:\($0.id)" == selected }), let room = board.plan.spatial?.rooms[index] {
            Text(room.name).font(.headline)
            Text("\(room.points.count) 段墙体 · 右键墙边加点，右键角点删除").font(.caption).foregroundStyle(.secondary)
            Stepper("展示墙高 \(room.wallHeight, specifier: "%.1f")", onIncrement: { wallHeight(index,delta:0.1) }, onDecrement: { wallHeight(index,delta:-0.1) })
            Button("移除墙体",role:.destructive) { board.checkpointLayout(); board.plan.spatial?.rooms.remove(at:index); self.selected = nil; board.saveLayout() }
        } else { Text("选中组件后，在这里调整。\n家具和设备可直接在画布上拖动。").font(.caption).foregroundStyle(.secondary) }
    }
    func resize(_ index: Int, width: Bool, delta: Double) {
        guard var f = board.plan.spatial?.furniture[index] else { return }; board.checkpointLayout()
        if width { f.width = min(1,max(0.01,f.width+delta)) } else { f.depth = min(1,max(0.01,f.depth+delta)) }
        board.plan.spatial?.furniture[index] = f; board.saveLayout()
    }
    func wallHeight(_ index: Int, delta: Double) {
        guard let h = board.plan.spatial?.rooms[index].wallHeight else { return }; board.checkpointLayout()
        board.plan.spatial?.rooms[index].wallHeight = min(3,max(0.1,h+delta)); board.saveLayout()
    }
    func finishRoom(_ room: BoardRoom) {
        var outline = SpatialRoom(id:room.id,name:room.name,points:draft)
        guard outline.isValidOutline else { board.error = "房间轮廓不能交叉、重复或连成一条直线，请调整描摹点。"; return }
        if let existing = board.plan.spatial?.rooms.first(where: { $0.id == room.id }) { outline.wallHeight = existing.wallHeight }
        guard board.finishRoomOutline(outline) else { return }
        draft = []; drawingRoom = nil; mode = "2d"
    }
}

struct SpatialTraceView: View {
    @ObservedObject var board: HomeBoardModel
    @Binding var selected: String?
    @Binding var draft: [PlanPoint]
    var drawing: Bool
    var snap: Bool
    var drawingRoomID: String?
    var close: () -> Void
    @State private var movingVertex = false
    @State private var snapPreview: LayoutSnapResult?

    var body: some View {
        GeometryReader { geo in
            let imageSize = board.planImage?.size ?? CGSize(width: 1000,height: 800)
            let scale = min(geo.size.width/imageSize.width,geo.size.height/imageSize.height)
            let size = CGSize(width:imageSize.width*scale,height:imageSize.height*scale)
            let origin = CGPoint(x:(geo.size.width-size.width)/2,y:(geo.size.height-size.height)/2)
            ZStack(alignment: .topLeading) {
                AppTheme.canvas
                if let image = board.planImage { Image(uiImage:image).resizable().frame(width:size.width,height:size.height).position(x:geo.size.width/2,y:geo.size.height/2) }
                ForEach(board.plan.spatial?.rooms ?? []) { room in
                    outline(room.points,size:size,origin:origin,closed:true).fill(spaceAccent.opacity(selected == "room:\(room.id)" ? 0.24 : 0.08))
                    outline(room.points,size:size,origin:origin,closed:true).stroke(spaceAccent,lineWidth:2)
                    Text(room.name).font(.caption.bold()).padding(5).background(.regularMaterial,in:Capsule()).position(x:origin.x+room.center.x*size.width,y:origin.y+room.center.y*size.height).onTapGesture { if !drawing { selected = "room:\(room.id)" } }
                    if !drawing, selected == "room:\(room.id)" {
                        ForEach(room.points.indices,id:\.self) { i in
                            Circle().fill(AppTheme.surface).overlay(Circle().stroke(spaceAccent,lineWidth:3)).frame(width:18,height:18)
                                .contentShape(Circle())
                                .accessibilityLabel("\(room.name)角点\(i + 1)")
                                .contextMenu {
                                    Button("删除此角点", role: .destructive) { board.removeRoomVertex(room, at: i) }
                                        .disabled(room.points.count <= 3 || movingVertex)
                                    if room.points.count <= 3 { Text("房间至少保留 3 个角点") }
                                }
                                .position(x:origin.x+room.points[i].x*size.width,y:origin.y+room.points[i].y*size.height)
                                .gesture(DragGesture(coordinateSpace:.named("trace")).onChanged { v in
                                    if !movingVertex { board.checkpointLayout(); movingVertex = true }
                                    if let index = board.plan.spatial?.rooms.firstIndex(where: { $0.id == room.id }) {
                                        let raw = point(v.location,size:size,origin:origin)
                                        snapPreview = snap ? board.snapLayoutPoint(raw, width: size.width, height: size.height, movingRoom: room.id, vertex: i) : nil
                                        board.plan.spatial?.rooms[index].points[i] = snapPreview?.point ?? raw
                                    }
                                }.onEnded { _ in movingVertex = false; snapPreview = nil; do { try board.plan.spatial?.validate(); board.saveLayout() } catch { board.undoLayout(); board.error = "轮廓不能交叉，已恢复拖动前的位置。" } })
                        }
                    }
                }
                if !drawing, let room = board.plan.spatial?.rooms.first(where: { "room:\($0.id)" == selected }) {
                    WallInsertionOverlay(room: room, origin: origin, imageSize: size, enabled: !movingVertex) { edge, fraction in
                        board.insertRoomVertex(room, on: edge, fraction: fraction)
                    }
                }
                if drawing {
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                        guard location.x >= origin.x, location.y >= origin.y, location.x <= origin.x+size.width, location.y <= origin.y+size.height else { return }
                        let raw = point(location,size:size,origin:origin)
                        if draft.count >= 3, let first = draft.first, hypot((raw.x-first.x)*size.width, (raw.y-first.y)*size.height) <= 14 { close(); snapPreview = nil; return }
                        let result = snap ? board.snapLayoutPoint(raw, width: size.width, height: size.height, excludingRoom: drawingRoomID, draft: draft) : nil
                        if result?.kind == .closure { close(); snapPreview = nil; return }
                        let next = result?.point ?? raw
                        guard draft.count < 100 else { board.error = "每个房间最多支持 100 个角点。"; return }
                        guard !draft.contains(where: { hypot(($0.x-next.x)*size.width, ($0.y-next.y)*size.height) < 2 }) else { board.error = "该角点已存在；完成描摹请点击起点闭合。"; return }
                        draft.append(next); snapPreview = nil
                    }
                    outline(draft,size:size,origin:origin,closed:false).stroke(.orange,style:StrokeStyle(lineWidth:3,dash:[6,4])).allowsHitTesting(false)
                    ForEach(draft.indices,id:\.self) { i in
                        Circle().fill(.orange).frame(width:18,height:18).contentShape(Circle())
                            .overlay(Circle().stroke(i == 0 && draft.count >= 3 ? spaceAccent : .clear, lineWidth: 3).padding(-4))
                            .accessibilityLabel(i == 0 && draft.count >= 3 ? "点击起点闭合房间" : "描摹点\(i + 1)")
                            .onTapGesture { if i == 0 && draft.count >= 3 { close(); snapPreview = nil } }
                            .contextMenu {
                                Button("删除此描摹点", role: .destructive) { if draft.indices.contains(i) { draft.remove(at: i) } }
                            }
                            .position(x:origin.x+draft[i].x*size.width,y:origin.y+draft[i].y*size.height)
                    }
                }
                if let result = snapPreview, result.kind != .none {
                    let at = CGPoint(x: origin.x+result.point.x*size.width, y: origin.y+result.point.y*size.height)
                    Path { path in
                        if result.alignX { path.move(to: CGPoint(x: at.x, y: origin.y)); path.addLine(to: CGPoint(x: at.x, y: origin.y+size.height)) }
                        if result.alignY { path.move(to: CGPoint(x: origin.x, y: at.y)); path.addLine(to: CGPoint(x: origin.x+size.width, y: at.y)) }
                        if drawing, let last = draft.last { path.move(to: CGPoint(x: origin.x+last.x*size.width, y: origin.y+last.y*size.height)); path.addLine(to: at) }
                    }.stroke(spaceAccent, style: StrokeStyle(lineWidth: 1, dash: [5,4])).allowsHitTesting(false)
                    Circle().stroke(spaceAccent, lineWidth: 2).frame(width: 24,height: 24).position(at).allowsHitTesting(false)
                    Text(result.label).font(.caption).padding(5).background(.regularMaterial,in:Capsule()).position(x:at.x,y:max(16,at.y-26)).allowsHitTesting(false)
                }
            }.coordinateSpace(name:"trace").clipped()
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard drawing else { return }
                        guard location.x >= origin.x, location.y >= origin.y, location.x <= origin.x+size.width, location.y <= origin.y+size.height else { snapPreview = nil; return }
                        let raw = point(location,size:size,origin:origin)
                        if snap { snapPreview = board.snapLayoutPoint(raw, width: size.width, height: size.height, excludingRoom: drawingRoomID, draft: draft) }
                        else { snapPreview = LayoutSnap.resolve(raw, width: size.width, height: size.height, anchors: [], edges: [], closeTo: draft.count >= 3 ? draft.first : nil, grid: false) }
                    case .ended: if !movingVertex { snapPreview = nil }
                    }
                }
                .onChange(of: drawing) { _ in snapPreview = nil }
                .onChange(of: snap) { _ in snapPreview = nil }
        }
    }
    func point(_ p: CGPoint,size:CGSize,origin:CGPoint) -> PlanPoint { PlanPoint(x:(p.x-origin.x)/max(1,size.width),y:(p.y-origin.y)/max(1,size.height)) }
    func outline(_ points:[PlanPoint],size:CGSize,origin:CGPoint,closed:Bool) -> Path {
        Path { path in for (i,p) in points.enumerated() { let xy = CGPoint(x:origin.x+p.x*size.width,y:origin.y+p.y*size.height); if i == 0 { path.move(to:xy) } else { path.addLine(to:xy) } }; if closed { path.closeSubpath() } }
    }
}
