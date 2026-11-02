import SwiftUI
import SceneKit

/// A real 3D scene: room floors, wall segments, furniture meshes and HomeKit pins.
struct SpatialSceneView: UIViewRepresentable {
    @ObservedObject var board: HomeBoardModel
    var editing: Bool
    var selected: String?
    @Binding var camera: SpatialCamera
    var labels: Bool
    var select: (String?) -> Void
    var open: (BoardDevice) -> Void
    var activate: ((BoardDevice) -> Void)? = nil
    var hoverChanged: (Bool) -> Void = { _ in }
    var embedded = false
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> SCNView {
        let view = LayoutAwareSceneView(); view.antialiasingMode = .multisampling4X
        view.backgroundColor = AppTheme.canvasUI
        let coordinator = context.coordinator
        let click = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        let doubleClick = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleClick.numberOfTapsRequired = 2
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.name = "canvas-drag"; pan.maximumNumberOfTouches = editing ? 1 : 2; pan.delegate = coordinator
        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.scroll(_:)))
        scroll.name = "canvas-scroll"; scroll.allowedScrollTypesMask = .all; scroll.allowedTouchTypes = []; scroll.delegate = coordinator
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.name = "canvas-pinch"; pinch.delegate = coordinator
        let hover = UIHoverGestureRecognizer(target: coordinator, action: #selector(Coordinator.hover(_:)))
        click.require(toFail: pan); click.require(toFail: pinch)
        if editing {
            click.require(toFail: doubleClick); doubleClick.require(toFail: pan)
            view.addGestureRecognizer(doubleClick)
        }
        for gesture in [click, pan, scroll, pinch, hover] { view.addGestureRecognizer(gesture) }
        NotificationCenter.default.addObserver(coordinator,selector:#selector(Coordinator.libraryDrop(_:)),name:.furnitureLibraryDrop,object:nil)
        view.addInteraction(UIDropInteraction(delegate: coordinator))
        view.addInteraction(UIContextMenuInteraction(delegate: coordinator))
        coordinator.tooltip.isUserInteractionEnabled = false
        coordinator.tooltip.backgroundColor = AppTheme.surfaceUI
        coordinator.tooltip.textColor = .label; coordinator.tooltip.font = .systemFont(ofSize: 12, weight: .medium)
        coordinator.tooltip.layer.cornerRadius = 7; coordinator.tooltip.clipsToBounds = true; coordinator.tooltip.isHidden = true
        view.addSubview(coordinator.tooltip)
        context.coordinator.view = view
        view.viewportChanged = { [weak coordinator] in coordinator?.applyCamera() }
        view.appearanceChanged = { [weak coordinator] in coordinator?.render() }
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render()
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIDropInteractionDelegate, UIContextMenuInteractionDelegate {
        var parent: SpatialSceneView
        var lastActivation: (id: String, time: TimeInterval)?
        weak var view: SCNView?
        var signature: String = ""
        var dragging: String?
        var dragOffset = SIMD2<Float>(0, 0)
        var mode = ""
        var lastTranslation = CGPoint.zero
        var focus = SCNVector3Zero
        var baseScale = 5.0
        let tooltip = UILabel()
        init(_ parent: SpatialSceneView) { self.parent = parent }
        var depth: Double { 12 * Double((parent.board.planImage?.size.height ?? 800) / (parent.board.planImage?.size.width ?? 1000)) }
        func world(_ p: PlanPoint, height: Float = 0) -> SCNVector3 { SCNVector3((p.x-0.5)*12, Double(height), (p.y-0.5)*depth) }
        func normalized(_ v: SCNVector3) -> PlanPoint { PlanPoint(x: Double(v.x)/12+0.5, y: Double(v.z)/depth+0.5) }
        func render() {
            guard let view else { return }
            view.traitCollection.performAsCurrent { renderScene() }
        }
        private func renderScene() {
            guard dragging == nil, let view else { return }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let hash = String(data: (try? encoder.encode(parent.board.plan)) ?? Data(), encoding: .utf8)! + "\(parent.selected ?? "")|\(parent.labels)|\(parent.editing)|\(parent.board.values)|\(parent.board.devices.map { parent.board.status($0) })|\(parent.board.planImage.map { String(describing: ObjectIdentifier($0)) } ?? "none")"
            let appearanceHash = hash + "|appearance:\(view.traitCollection.userInterfaceStyle.rawValue)"
            guard appearanceHash != signature else { applyCamera(); return }; signature = appearanceHash; tooltip.isHidden = true
            let scene = SCNScene(); view.scene = scene
            let root = scene.rootNode
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 500; root.addChildNode(ambient)
            let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 800; sun.light?.castsShadow = true
            sun.light?.shadowMode = .deferred; sun.light?.shadowRadius = 5; sun.light?.shadowColor = UIColor.black.withAlphaComponent(0.16)
            sun.eulerAngles = SCNVector3(-Double.pi/3, -Double.pi/5, 0); root.addChildNode(sun)
            let rooms = parent.board.plan.spatial?.rooms ?? []
            if rooms.isEmpty {
                let base = SCNPlane(width: 12, height: depth); base.firstMaterial?.diffuse.contents = parent.board.planImage ?? AppTheme.surfaceUI.resolvedColor(with: view.traitCollection)
                base.firstMaterial?.isDoubleSided = true
                let node = SCNNode(geometry: base); node.eulerAngles.x = -.pi/2; root.addChildNode(node)
            }
            for room in rooms {
                let path = UIBezierPath()
                for (i, point) in room.points.enumerated() { let p = world(point); if i == 0 { path.move(to: CGPoint(x: CGFloat(p.x), y: CGFloat(-p.z))) } else { path.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(-p.z))) } }
                path.close()
                let floor = SCNShape(path: path, extrusionDepth: 0.06)
                floor.firstMaterial?.diffuse.contents = room.name.contains("卫") || room.name.contains("厨") ? AppTheme.wetRoomUI.resolvedColor(with: view.traitCollection) : AppTheme.roomUI.resolvedColor(with: view.traitCollection)
                let floorNode = SCNNode(geometry: floor); floorNode.eulerAngles.x = -.pi/2; floorNode.name = "room:\(room.id)"; root.addChildNode(floorNode)
                for i in room.points.indices {
                    let a = world(room.points[i]), b = world(room.points[(i+1)%room.points.count])
                    let dx = b.x-a.x, dz = b.z-a.z, length = sqrt(dx*dx+dz*dz)
                    let wall = box(CGFloat(length), CGFloat(room.wallHeight), 0.065, color: AppTheme.wall3DUI.resolvedColor(with: view.traitCollection), radius: 0.012)
                    wall.position = SCNVector3((a.x+b.x)/2, Float(room.wallHeight)/2+0.06, (a.z+b.z)/2)
                    wall.eulerAngles.y = -atan2(dz, dx); wall.name = "room:\(room.id)"; root.addChildNode(wall)
                }
                let label = textNode(room.name, color: UIColor.label, width: 0.85)
                label.position = world(room.center, height: 0.13); label.eulerAngles.x = -.pi/2; label.name = "room:\(room.id)"; root.addChildNode(label)
            }
            for f in parent.board.plan.spatial?.furniture ?? [] {
                let node = furniture(f); node.name = "furniture:\(f.id)"; node.position = world(f.point, height: 0.08)
                node.eulerAngles.y = Float(-f.rotation * .pi / 180)
                if parent.selected == node.name { highlight(node, width: f.width*12, length: f.depth*depth) }
                root.addChildNode(node)
            }
            addLighting(to: root)
            for device in parent.board.devices {
                guard let point = parent.board.plan.devices[device.id] else { continue }
                let pin = SCNNode(); pin.name = "device:\(device.id)"; pin.position = world(point, height: 0.7)
                let style = DeviceAppearance(state: parent.board.visualState(device))
                let color = style.ink
                let plate = SCNPlane(width: 0.46, height: 0.46); plate.firstMaterial?.diffuse.contents = style.image(symbol: device.icon)
                plate.firstMaterial?.lightingModel = .constant; plate.firstMaterial?.isDoubleSided = true
                let node = SCNNode(geometry: plate); node.constraints = [SCNBillboardConstraint()]; pin.addChildNode(node)
                let stem = SCNCylinder(radius: 0.012, height: 0.6); stem.firstMaterial?.diffuse.contents = color
                let stemNode = SCNNode(geometry: stem); stemNode.position.y = -0.3; pin.addChildNode(stemNode)
                if parent.labels || parent.selected == pin.name {
                    let label = textNode("\(device.name) · \(parent.board.status(device))", color: .label, width: 1.05); label.position.y = 0.42; label.constraints = [SCNBillboardConstraint()]; pin.addChildNode(label)
                }
                if !parent.labels && parent.selected != pin.name && !parent.board.sensorSummary(device).isEmpty {
                    let label = textNode(parent.board.sensorSummary(device), color: .label, width: 0.85)
                    label.position.y = 0.42; label.constraints = [SCNBillboardConstraint()]; pin.addChildNode(label)
                }
                if parent.selected == pin.name { highlight(pin, width: 0.4, length: 0.4) }
                root.addChildNode(pin)
            }
            let points = rooms.flatMap(\.points)
            let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 1
            let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 1
            focus = world(PlanPoint(x: (minX+maxX)/2, y: (minY+maxY)/2), height: 0.25)
            let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.usesOrthographicProjection = true
            baseScale = max(2, max((maxX-minX)*12, (maxY-minY)*depth) * 0.48)
            camera.camera?.zNear = 0.01; camera.camera?.zFar = 100
            root.addChildNode(camera); view.pointOfView = camera; applyCamera()
        }
        func addLighting(to root: SCNNode) {
            let sources = LightingAppearance.sources(board: parent.board, plan: parent.board.plan, aspect: depth / 12)
            let groups = Dictionary(grouping: sources) { $0.room?.id ?? "unbounded" }
            for lights in groups.values {
                guard let first = lights.first else { continue }
                let points = first.room?.points ?? [PlanPoint(x: 0, y: 0), PlanPoint(x: 1, y: 1)]
                let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 1
                let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 1
                let bounds = CGRect(x: minX, y: minY, width: maxX-minX, height: maxY-minY)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let plane = SCNPlane(width: bounds.width * 12, height: bounds.height * depth)
                let material = SCNMaterial()
                material.diffuse.contents = LightingAppearance.texture(lights, bounds: bounds, aspect: depth / 12)
                material.lightingModel = .constant; material.isDoubleSided = true
                material.writesToDepthBuffer = false
                plane.materials = [material]
                let node = SCNNode(geometry: plane)
                node.position = world(PlanPoint(x: bounds.midX, y: bounds.midY), height: first.room == nil ? 0.005 : 0.065)
                node.eulerAngles.x = -.pi/2
                root.addChildNode(node)
            }
        }
        var viewportBaseScale: Double {
            #if targetEnvironment(macCatalyst)
            return baseScale
            #else
            guard let size = view?.bounds.size, size.width > 0, size.height > 0 else { return baseScale }
            // Orthographic scale measures vertical extent; portrait views need room for the width too.
            return baseScale * 1.6 / min(1, Double(size.width / size.height))
            #endif
        }
        func applyCamera() {
            guard let node = view?.pointOfView else { return }
            let state = parent.camera
            let target = SCNVector3(focus.x + Float(state.offsetX), focus.y, focus.z + Float(state.offsetZ))
            let yaw = state.yaw * .pi / 180, elevation = state.elevation * .pi / 180
            node.camera?.orthographicScale = viewportBaseScale / state.zoom
            node.position = SCNVector3(target.x + Float(sin(yaw)*20*cos(elevation)), target.y + Float(20*sin(elevation)), target.z + Float(cos(yaw)*20*cos(elevation)))
            node.look(at: target)
        }
        func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, color: UIColor, radius: CGFloat = 0.035) -> SCNNode {
            let shape = SCNBox(width: w, height: h, length: d, chamferRadius: min(radius, min(w,h,d)/3)); shape.firstMaterial?.diffuse.contents = color
            shape.firstMaterial?.roughness.contents = 0.85
            return SCNNode(geometry: shape)
        }
        func furniture(_ f: SpatialFurniture) -> SCNNode {
            let root = SCNNode(), w = CGFloat(f.width*12), d = CGFloat(f.depth*depth)
            if f.kind == "model", let asset = FurnitureLibrary.shared.asset(f.assetID), let model = FurnitureLibrary.shared.node(asset,width:w,depth:d) { return model }
            let wood = UIColor(red: 0.55, green: 0.39, blue: 0.25, alpha: 1), fabric = UIColor(red: 0.68, green: 0.76, blue: 0.71, alpha: 1)
            func part(_ width: CGFloat, _ height: CGFloat, _ length: CGFloat, _ x: Float, _ y: Float, _ z: Float, _ color: UIColor) {
                let n = box(width,height,length,color:color); n.position = SCNVector3(x,y,z); root.addChildNode(n)
            }
            func oval(_ width: CGFloat, _ height: CGFloat, _ length: CGFloat, _ y: Float, _ z: Float, _ color: UIColor) {
                let shape = SCNCylinder(radius: 0.5, height: 1)
                shape.firstMaterial?.diffuse.contents = color; shape.firstMaterial?.roughness.contents = 0.25
                let node = SCNNode(geometry: shape)
                node.scale = SCNVector3(Float(width),Float(height),Float(length)); node.position = SCNVector3(0,y,z)
                root.addChildNode(node)
            }
            switch f.kind {
            case "stove":
                part(w,0.65,d,0,0.325,0,wood)
                part(w,0.06,d,0,0.68,0,UIColor(white:0.18,alpha:1))
                for x in [-0.25,0.25] {
                    let burner = SCNTorus(ringRadius:min(w*0.17,d*0.27),pipeRadius:0.015)
                    burner.firstMaterial?.diffuse.contents = UIColor.lightGray
                    let node = SCNNode(geometry:burner); node.position = SCNVector3(Float(w*x),0.725,Float(-d*0.08)); root.addChildNode(node)
                    part(w*0.05,0.025,d*0.07,Float(w*x),0.723,Float(d*0.34),.lightGray)
                }
            case "fridge":
                let metal = UIColor(red:0.78,green:0.82,blue:0.84,alpha:1)
                part(w,1.65,d,0,0.825,0,metal)
                part(w*0.94,1.03,0.035,0,1.09,Float(d/2),UIColor(white:0.91,alpha:1))
                part(w*0.94,0.48,0.035,0,0.28,Float(d/2),UIColor(white:0.86,alpha:1))
                part(w*0.055,0.28,0.055,Float(-w*0.32),0.87,Float(d/2+0.035),.darkGray)
                part(w*0.55,0.035,0.055,0,0.44,Float(d/2+0.035),.darkGray)
            case "counter":
                part(w,0.65,d,0,0.325,0,wood)
                for x in [-0.25,0.25] {
                    part(w*0.47,0.57,0.025,Float(w*x),0.34,Float(d/2),UIColor(red:0.80,green:0.75,blue:0.66,alpha:1))
                    part(w*0.18,0.025,0.045,Float(w*x),0.55,Float(d/2+0.025),.darkGray)
                }
                part(w*1.02,0.055,d*1.02,0,0.68,0,UIColor(red:0.93,green:0.92,blue:0.87,alpha:1))
            case "rangeHood":
                part(w,0.12,d,0,1.45,0,.lightGray)
                part(w*0.48,0.55,d*0.48,0,1.78,Float(-d*0.20),UIColor(white:0.83,alpha:1))
                part(w*0.88,0.035,0.025,0,1.45,Float(d/2),.darkGray)
                for x in [-0.33,0.33] { part(w*0.07,0.008,d*0.1,Float(w*x),1.385,Float(d*0.25),UIColor(white:0.95,alpha:1)) }
            case "toilet":
                let ceramic = UIColor(red:0.84,green:0.91,blue:0.92,alpha:1)
                oval(w*0.48,0.25,d*0.45,0.13,Float(d*0.09),.white)
                oval(w*0.88,0.16,d*0.68,0.33,Float(d*0.12),.white)
                oval(w*0.62,0.008,d*0.43,0.415,Float(d*0.14),ceramic)
                part(w*0.92,0.62,d*0.25,0,0.31,Float(-d*0.37),.white)
                part(w*0.18,0.012,d*0.07,0,0.628,Float(-d*0.37),.lightGray)
            case "sink":
                part(w*0.90,0.56,d*0.90,0,0.28,0,UIColor(red:0.78,green:0.72,blue:0.62,alpha:1))
                part(w,0.08,d,0,0.60,0,.white)
                part(w*0.70,0.008,d*0.60,0,0.645,Float(d*0.06),UIColor(red:0.72,green:0.85,blue:0.87,alpha:1))
                oval(w*0.06,0.008,w*0.06,0.652,Float(d*0.13),.darkGray)
                part(w*0.055,0.20,d*0.08,0,0.74,Float(-d*0.35),.lightGray)
                part(w*0.055,0.035,d*0.30,0,0.835,Float(-d*0.23),.lightGray)
            case "bed":
                part(w,0.18,d,0,0.09,0,wood); part(w*0.96,0.16,d*0.93,0,0.26,0,.white)
                part(w*0.98,0.55,0.08,0,0.28,Float(-d/2),wood)
                part(w*0.95,0.05,d*0.58,0,0.36,Float(d*0.16),fabric)
                for x in [-0.25,0.25] { part(w*0.38,0.09,d*0.18,Float(w*x),0.38,Float(-d*0.31),.white) }
            case "sofa":
                part(w,0.35,d,0,0.18,0,fabric); part(w,0.55,d*0.2,0,0.35,Float(-d*0.4),fabric)
                for x in [-0.44,0.44] { part(w*0.12,0.48,d,Float(w*x),0.28,0,fabric) }
                for x in [-0.22,0.22] { part(w*0.4,0.06,d*0.7,Float(w*x),0.4,Float(d*0.05),UIColor(red:0.8,green:0.85,blue:0.81,alpha:1)) }
            case "table":
                part(w,0.08,d,0,0.5,0,wood)
                for x in [-0.35,0.35] { for z in [-0.35,0.35] { part(0.045,0.48,0.045,Float(w*x),0.24,Float(d*z),wood) } }
            case "plant":
                let pot = SCNCylinder(radius: min(w,d)*0.3,height: 0.3); pot.firstMaterial?.diffuse.contents = UIColor.white
                let n = SCNNode(geometry: pot); n.position.y = 0.15; root.addChildNode(n)
                for i in 0..<3 { let leaf = SCNSphere(radius: min(w,d)*0.4); leaf.firstMaterial?.diffuse.contents = UIColor(red: 0.23,green: 0.43,blue: 0.27,alpha: 1); let node = SCNNode(geometry: leaf); node.position = SCNVector3(Float(i-1)*0.08,0.42+Float(i)*0.1,0); root.addChildNode(node) }
            case "bath":
                part(w,0.32,d,0,0.16,0,.white); part(w*0.72,0.02,d*0.78,0,0.33,0,UIColor(red:0.65,green:0.8,blue:0.83,alpha:1))
            default: part(w,0.7,d,0,0.35,0,wood); part(w*0.96,0.03,d*0.96,0,0.72,0,.white)
            }
            return root
        }
        func highlight(_ node: SCNNode, width: Double, length: Double) {
            let ring = box(CGFloat(width+0.08),0.015,CGFloat(length+0.08),color:UIColor.systemTeal.withAlphaComponent(0.5))
            ring.position.y = -0.015; node.addChildNode(ring)
        }
        func textNode(_ text: String, color: UIColor, width: CGFloat) -> SCNNode {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 360,height: 82)).image { _ in
                AppTheme.surfaceUI.withAlphaComponent(0.95).setFill(); UIBezierPath(roundedRect: CGRect(x:0,y:0,width:360,height:82),cornerRadius: 20).fill()
                let style = NSMutableParagraphStyle(); style.alignment = .center
                (text as NSString).draw(in: CGRect(x:8,y:17,width:344,height:60),withAttributes:[.font:UIFont.systemFont(ofSize:32,weight:.semibold),.foregroundColor:color,.paragraphStyle:style])
            }
            let plane = SCNPlane(width: width,height: width*82/360); plane.firstMaterial?.diffuse.contents = image; plane.firstMaterial?.lightingModel = .constant; plane.firstMaterial?.isDoubleSided = true
            return SCNNode(geometry: plane)
        }
        func target(at point: CGPoint) -> String? {
            guard let view else { return nil }
            for hit in view.hitTest(point, options: nil) {
                var n: SCNNode? = hit.node
                while let node = n { if let name = node.name, name.hasPrefix("device:") || name.hasPrefix("furniture:") || name.hasPrefix("room:") { return name }; n = node.parent }
            }
            return nil
        }
        func floorPoint(_ point: CGPoint) -> SCNVector3? {
            guard let view else { return nil }
            let a = view.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),0)), b = view.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),1))
            guard abs(b.y-a.y)>0.00001 else { return nil }
            let t = -a.y/(b.y-a.y)
            return SCNVector3(a.x+t*(b.x-a.x),0,a.z+t*(b.z-a.z))
        }
        @objc func libraryDrop(_ notification:Notification) {
            guard parent.editing, let view, let window = view.window, notification.object as? UIWindow === window,
                  let location = notification.userInfo?["point"] as? NSValue,
                  let payload = notification.userInfo?["payload"] as? String else { return }
            let at = view.convert(location.cgPointValue,from:window)
            guard view.bounds.contains(at) else { return }
            guard let raw = floorPoint(at) else { return }
            let position = normalized(raw)
            if payload.hasPrefix("home-model:"), let asset = FurnitureLibrary.shared.asset(String(payload.dropFirst("home-model:".count))) { parent.select(parent.board.addModel(asset,at:position)) }
            else if payload.hasPrefix("home-furniture:") {
                let kind = String(payload.dropFirst("home-furniture:".count))
                if SpatialFurniture.kinds.contains(kind) { parent.select(parent.board.addFurniture(kind,at:position)) }
            }
        }
        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            parent.editing && session.canLoadObjects(ofClass: NSString.self)
        }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal { UIDropProposal(operation: parent.editing ? .copy : .forbidden) }
        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard parent.editing, let view, let raw = floorPoint(session.location(in: view)) else { return }; let point = normalized(raw)
            session.loadObjects(ofClass: NSString.self) { [weak self] items in
                Task { @MainActor in
                    guard let self, self.parent.editing, let text = items.first as? String else { return }
                    if text.hasPrefix("home-device:"), let device = self.parent.board.devices.first(where: { "home-device:\($0.id)" == text }) {
                        self.parent.board.checkpointLayout(); self.parent.board.place(device.id, room: false, at: point); self.parent.select("device:\(device.id)")
                    } else if text.hasPrefix("home-model:"), let asset = FurnitureLibrary.shared.asset(String(text.dropFirst("home-model:".count))) {
                        self.parent.select(self.parent.board.addModel(asset,at:point))
                    } else if text.hasPrefix("home-furniture:") {
                        let kind = String(text.dropFirst("home-furniture:".count))
                        if SpatialFurniture.kinds.contains(kind) { self.parent.select(self.parent.board.addFurniture(kind, at: point)) }
                    }
                }
            }
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            let name = target(at: gesture.location(in: view)); parent.select(name)
            if !parent.editing, let name, let device = device(name) {
                let now = ProcessInfo.processInfo.systemUptime
                guard lastActivation?.id != device.id || now - (lastActivation?.time ?? 0) >= 0.45 else { return }
                lastActivation = (device.id, now)
                parent.activate?(device)
            }
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            if let name = target(at: gesture.location(in: view)), let device = device(name) {
                parent.select(name); if !parent.editing, let activate = parent.activate { activate(device) } else { parent.open(device) }
            } else if target(at: gesture.location(in: view)) == nil { parent.camera = SpatialCamera(); applyCamera() }
        }
        func device(_ name: String) -> BoardDevice? { parent.board.devices.first { "device:\($0.id)" == name } }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer.name == "canvas-drag" { return !gestureRecognizer.buttonMask.contains(.secondary) }
            return dragging == nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // The canvas owns mouse scrolling and dragging; its enclosing page must wait.
            guard gestureRecognizer.name == "canvas-scroll" || gestureRecognizer.name == "canvas-drag" || (parent.embedded && gestureRecognizer.name == "canvas-pinch"), let view, let otherView = other.view, otherView !== view else { return false }
            return view.isDescendant(of: otherView) && other is UIPanGestureRecognizer
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard !parent.editing, g.view === other.view else { return false }
            return (g.name == "canvas-drag" && other.name == "canvas-pinch") || (g.name == "canvas-pinch" && other.name == "canvas-drag")
        }
        @objc func scroll(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in: view); gesture.setTranslation(.zero,in:view)
            if gesture.modifierFlags.contains(.shift) { panCamera(delta) }
            else { parent.camera.scroll(Double(delta.y)); applyCamera() }
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            parent.camera.magnify(Double(gesture.scale)); gesture.scale = 1; applyCamera()
        }
        func panCamera(_ delta: CGPoint) {
            parent.camera.pan(dx:Double(delta.x),dy:Double(delta.y),unitsPerPoint:2*viewportBaseScale/parent.camera.zoom/Double(max(1,view?.bounds.height ?? 1)))
            applyCamera()
        }
        @objc func hover(_ gesture: UIHoverGestureRecognizer) {
            let inside = gesture.state != .ended && gesture.state != .cancelled
            parent.hoverChanged(inside)
            guard inside, dragging == nil, let view, let name = target(at:gesture.location(in:view)) else { tooltip.isHidden = true; return }
            let title: String
            if let device = device(name) { title = "\(device.name) · \(parent.board.status(device)) · " + (parent.editing ? "双击控制" : device.supportsDirectPower ? "单击切换 · 右键详情" : "单击控制") }
            else if let f = parent.board.plan.spatial?.furniture.first(where:{ "furniture:\($0.id)" == name }) { title = parent.editing ? "\(FurnitureLibrary.shared.title(f)) · 拖动移动 · 右键编辑" : "\(FurnitureLibrary.shared.title(f)) · 在布置空间中编辑" }
            else { tooltip.isHidden = true; return }
            tooltip.text = "  " + title + "  "; tooltip.sizeToFit()
            let point = gesture.location(in:view)
            tooltip.frame = CGRect(x:max(4,min(view.bounds.width-tooltip.bounds.width-4,point.x+14)),y:max(4,min(view.bounds.height-30,point.y+20)),width:tooltip.bounds.width,height:26)
            tooltip.isHidden = false
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            if !parent.editing && dragging != nil {
                dragging = nil; mode = ""; signature = ""; render(); return
            }
            let location = gesture.location(in:view), translation = gesture.translation(in:view)
            if gesture.state == .began {
                tooltip.isHidden = true; lastTranslation = .zero
                let start = CGPoint(x:location.x-translation.x,y:location.y-translation.y)
                if gesture.modifierFlags.contains(.shift) || (!parent.editing && gesture.numberOfTouches > 1) { mode = "pan" }
                else if parent.editing, let name = target(at:start), name.hasPrefix("device:") || name.hasPrefix("furniture:"),
                        let node = view.scene?.rootNode.childNode(withName:name,recursively:false), let p = floorPoint(start) {
                    mode = "item"; dragging = name; dragOffset = SIMD2(node.position.x-p.x,node.position.z-p.z); parent.select(name)
                } else { mode = "orbit" }
            }
            let delta = CGPoint(x:translation.x-lastTranslation.x,y:translation.y-lastTranslation.y); lastTranslation = translation
            if !parent.editing && gesture.numberOfTouches > 0 { mode = gesture.numberOfTouches > 1 || gesture.modifierFlags.contains(.shift) ? "pan" : "orbit" }
            if mode == "orbit" { parent.camera.orbit(dx:Double(delta.x),dy:Double(delta.y)); applyCamera() }
            else if mode == "pan" { panCamera(delta) }
            else if let name = dragging, let node = view.scene?.rootNode.childNode(withName:name,recursively:false), let p = floorPoint(location) {
                let point = normalized(SCNVector3(p.x+dragOffset.x,0,p.z+dragOffset.y)), position = world(point)
                node.position.x = position.x; node.position.z = position.z
                if gesture.state == .ended {
                    let id = String(name.split(separator:":",maxSplits:1)[1])
                    parent.board.checkpointLayout()
                    if name.hasPrefix("device:") { parent.board.plan.devices[id] = point }
                    else if let i = parent.board.plan.spatial?.furniture.firstIndex(where:{ $0.id == id }) { parent.board.plan.spatial?.furniture[i].point = point }
                    parent.board.saveLayout()
                }
            }
            if [.ended,.cancelled,.failed].contains(gesture.state) {
                let movedItem = dragging != nil; dragging = nil; mode = ""
                if movedItem { signature = ""; render() }
            }
        }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            let name = target(at:location)
            let position = floorPoint(location).map(normalized) ?? PlanPoint(x:0.5,y:0.5)
            parent.select(name); tooltip.isHidden = true
            return UIContextMenuConfiguration(identifier:nil,previewProvider:nil) { [weak self] _ in
                guard let self else { return nil }
                var actions: [UIMenuElement] = []
                if let name, let device = self.device(name) {
                    actions.append(UIAction(title:"打开设备控制",image:UIImage(systemName:"slider.horizontal.3")) { _ in self.parent.open(device) })
                    if self.parent.editing { actions.append(UIAction(title:"从画布移除",image:UIImage(systemName:"minus.circle")) { _ in guard self.parent.editing else { return }; self.parent.board.checkpointLayout(); self.parent.board.unplace(device.id,room:false); self.parent.select(nil) }) }
                } else if let name, self.parent.editing, let f = self.parent.board.plan.spatial?.furniture.first(where:{ "furniture:\($0.id)" == name }) {
                    actions += [
                        UIAction(title:"向左旋转 15°",image:UIImage(systemName:"rotate.left")) { _ in self.editFurniture(f.id,rotation:-15) },
                        UIAction(title:"向右旋转 15°",image:UIImage(systemName:"rotate.right")) { _ in self.editFurniture(f.id,rotation:15) },
                        UIAction(title:"放大家具",image:UIImage(systemName:"plus.magnifyingglass")) { _ in self.editFurniture(f.id,scale:1.1) },
                        UIAction(title:"缩小家具",image:UIImage(systemName:"minus.magnifyingglass")) { _ in self.editFurniture(f.id,scale:1/1.1) },
                        UIAction(title:"移除家具",image:UIImage(systemName:"minus.circle")) { _ in
                            guard self.parent.editing else { return }
                            self.parent.board.checkpointLayout(); self.parent.board.plan.spatial?.furniture.removeAll { $0.id == f.id }; self.parent.board.saveLayout(); self.parent.select(nil)
                        }
                    ]
                } else if self.parent.editing {
                    actions.append(UIMenu(title:"在此添加家具",image:UIImage(systemName:"sofa.fill"),children:SpatialFurniture.kinds.map { kind in
                        UIAction(title:SpatialFurniture.title(kind),image:UIImage(systemName:SpatialFurniture.icon(kind))) { _ in guard self.parent.editing else { return }; self.parent.select(self.parent.board.addFurniture(kind,at:position)) }
                    }))
                    let missing = self.parent.board.devices.filter { self.parent.board.plan.devices[$0.id] == nil }
                    if !missing.isEmpty { actions.append(UIMenu(title:"在此放入设备",image:UIImage(systemName:"lightbulb"),children:missing.map { device in
                        UIAction(title:"\(device.roomName) · \(device.name)") { _ in guard self.parent.editing else { return }; self.parent.board.checkpointLayout(); self.parent.board.place(device.id,room:false,at:position); self.parent.select("device:\(device.id)") }
                    })) }
                }
                if self.parent.editing && !self.parent.board.layoutUndo.isEmpty { actions.append(UIAction(title:"撤销上一步布局修改",image:UIImage(systemName:"arrow.uturn.backward")) { _ in guard self.parent.editing else { return }; self.parent.board.undoLayout() }) }
                actions.append(UIAction(title:"复位视角",image:UIImage(systemName:"viewfinder")) { _ in self.parent.camera = SpatialCamera(); self.applyCamera() })
                return UIMenu(children:actions)
            }
        }
        func editFurniture(_ id: String, rotation: Double = 0, scale: Double = 1) {
            guard parent.editing, let index = parent.board.plan.spatial?.furniture.firstIndex(where:{ $0.id == id }), var f = parent.board.plan.spatial?.furniture[index] else { return }
            parent.board.checkpointLayout()
            f.rotation = (f.rotation+rotation).truncatingRemainder(dividingBy:360)
            f.width = min(1,max(0.005,f.width*scale)); f.depth = min(1,max(0.005,f.depth*scale))
            parent.board.plan.spatial?.furniture[index] = f; parent.board.saveLayout()
        }
    }
}

private final class LayoutAwareSceneView: SCNView {
    var viewportChanged: (() -> Void)?
    var appearanceChanged: (() -> Void)?
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { appearanceChanged?() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        viewportChanged?()
    }
}
