import SwiftUI

private let planTint = AppTheme.accentUI
final class PlanCanvas: UIView {
    var paint: ((CGContext) -> Void)?
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { setNeedsDisplay() }
    }
    override func draw(_ rect: CGRect) { if let context = UIGraphicsGetCurrentContext() { paint?(context) } }
}

struct PlanEditorView: UIViewRepresentable {
    @ObservedObject var board: HomeBoardModel
    var editing: Bool
    @Binding var viewport: PlanViewport
    var selected: String?
    var background: Bool
    var snap: Bool
    var select: (String?) -> Void
    var open: (BoardDevice) -> Void
    var activate: ((BoardDevice) -> Void)? = nil
    var hoverChanged: (Bool) -> Void = { _ in }
    var embedded = false
    var displayQuarterTurns: Int? = 0
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PlanCanvas {
        let view = PlanCanvas(); view.backgroundColor = AppTheme.canvasUI; view.contentMode = .redraw
        let c = context.coordinator; c.view = view; view.paint = { [weak c] in c?.draw($0) }
        let click = UITapGestureRecognizer(target:c,action:#selector(Coordinator.click(_:)))
        let double = UITapGestureRecognizer(target:c,action:#selector(Coordinator.doubleClick(_:))); double.numberOfTapsRequired = 2
        let drag = UIPanGestureRecognizer(target:c,action:#selector(Coordinator.drag(_:))); drag.maximumNumberOfTouches = editing ? 1 : 2; drag.name = "plan-drag"; drag.delegate = c
        let wheel = UIPanGestureRecognizer(target:c,action:#selector(Coordinator.wheel(_:))); wheel.allowedTouchTypes = []; wheel.allowedScrollTypesMask = .all; wheel.name = "plan-wheel"; wheel.delegate = c
        let pinch = UIPinchGestureRecognizer(target:c,action:#selector(Coordinator.pinch(_:))); pinch.name = "plan-pinch"; pinch.delegate = c
        let hover = UIHoverGestureRecognizer(target:c,action:#selector(Coordinator.hover(_:)))
        click.require(toFail:drag); click.require(toFail:pinch)
        // Overview is a control surface: do not delay its single click while
        // Catalyst waits to rule out an editing double click.
        if editing {
            click.require(toFail:double); double.require(toFail:drag)
            view.addGestureRecognizer(double)
        }
        for g in [click,drag,wheel,pinch,hover] { view.addGestureRecognizer(g) }
        NotificationCenter.default.addObserver(c,selector:#selector(Coordinator.libraryDrop(_:)),name:.furnitureLibraryDrop,object:nil)
        view.addInteraction(UIContextMenuInteraction(delegate:c)); view.addInteraction(UIDropInteraction(delegate:c))
        return view
    }
    func updateUIView(_ view:PlanCanvas,context:Context) { context.coordinator.parent = self; if !editing { context.coordinator.preview = nil; context.coordinator.baseline = nil }; view.setNeedsDisplay() }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate, UIDropInteractionDelegate {
        var parent: PlanEditorView
        weak var view: PlanCanvas?
        var preview: FloorPlanLayout?
        var baseline: FloorPlanLayout?
        var action = ""
        var subject: String?
        var vertex = 0
        var offset = CGPoint.zero
        var lastTranslation = CGPoint.zero
        var dragOrigin: CGPoint?
        var snapResult: LayoutSnapResult?
        var hoverName: String?
        var lastActivation: (id: String, time: TimeInterval)?
        var icons: [String:UIImage] = [:]
        var iconStyle: UIUserInterfaceStyle = .unspecified
        init(_ parent: PlanEditorView) { self.parent = parent }
        var plan: FloorPlanLayout { preview ?? parent.board.plan }
        var projection: PlanProjection {
            let size = parent.board.planImage?.size ?? CGSize(width:1000,height:800)
            return PlanProjection(imageWidth:size.width,imageHeight:size.height,width:Double(view?.bounds.width ?? 1),height:Double(view?.bounds.height ?? 1),points:parent.board.plan.spatial?.rooms.flatMap(\.points) ?? [],state:parent.viewport,quarterTurns:parent.displayQuarterTurns,padding:parent.embedded ? 18 : 32)
        }
        func screen(_ p:PlanPoint) -> CGPoint { let q = projection.screen(p); return CGPoint(x:q.x,y:q.y) }
        func point(_ p:CGPoint) -> PlanPoint {
            let projection = projection
            let raw = projection.point(x: p.x, y: p.y)
            guard parent.snap else { snapResult = nil; return raw }
            let result = parent.board.snapLayoutPoint(raw, width: projection.imageWidth*projection.scale, height: projection.imageHeight*projection.scale,
                                                     movingRoom: action == "vertex" ? subject : nil, vertex: action == "vertex" ? vertex : nil)
            if baseline != nil { snapResult = result }
            return result.point
        }
        func roomPath(_ room:SpatialRoom) -> UIBezierPath {
            let path = UIBezierPath()
            for (i,p) in room.points.enumerated() { if i == 0 { path.move(to:screen(p)) } else { path.addLine(to:screen(p)) } }
            path.close(); return path
        }
        // Screen-only decluttering. Saved coordinates and light sources remain untouched.
        func deviceCenters() -> [String:CGPoint] {
            let devices = parent.board.devices.filter { plan.devices[$0.id] != nil }.sorted { $0.id < $1.id }
            var result: [String:CGPoint] = [:]
            for device in devices {
                guard let point = plan.devices[device.id] else { continue }
                let actual = screen(point)
                guard parent.embedded, let view else { result[device.id] = actual; continue }
                let room = plan.spatial?.rooms.first { $0.contains(point) }
                var candidates = [actual]
                for radius in stride(from:8.0,through:48.0,by:8) {
                    for step in 0..<16 {
                        let angle = Double(step)*Double.pi/8
                        candidates.append(CGPoint(x:actual.x+cos(angle)*radius,y:actual.y+sin(angle)*radius))
                    }
                }
                let valid = candidates.filter { candidate in
                    guard view.bounds.insetBy(dx:18,dy:18).contains(candidate) else { return false }
                    if let room { return room.contains(projection.point(x:candidate.x,y:candidate.y)) }
                    return true
                }
                let placed = Array(result.values)
                result[device.id] = valid.first { candidate in placed.allSatisfy { distance($0,candidate) >= 32 } } ?? actual
            }
            return result
        }
        func draw(_ context:CGContext) {
            guard let view else { return }
            if iconStyle != view.traitCollection.userInterfaceStyle { icons.removeAll(keepingCapacity: true); iconStyle = view.traitCollection.userInterfaceStyle }
            let p = projection
            context.saveGState(); context.clip(to:view.bounds)
            context.setStrokeColor(AppTheme.gridUI.cgColor); context.setLineWidth(0.5)
            if 0.02*p.imageWidth*p.scale >= 7 {
                for x in stride(from:0.0,through:1.0,by:0.02) { context.move(to:screen(PlanPoint(x:x,y:0))); context.addLine(to:screen(PlanPoint(x:x,y:1))) }
                for y in stride(from:0.0,through:1.0,by:0.02*p.imageWidth/p.imageHeight) { context.move(to:screen(PlanPoint(x:0,y:y))); context.addLine(to:screen(PlanPoint(x:1,y:y))) }
                context.strokePath()
            }
            if let image = parent.board.planImage, parent.background || plan.spatial?.rooms.isEmpty != false {
                let origin = screen(PlanPoint(x:0,y:0))
                context.saveGState(); context.translateBy(x:origin.x,y:origin.y); context.rotate(by:p.rotation)
                image.draw(in:CGRect(x:0,y:0,width:p.imageWidth*p.scale,height:p.imageHeight*p.scale),blendMode:.normal,alpha:parent.background ? 0.55 : 1)
                context.restoreGState()
            }
            for room in plan.spatial?.rooms ?? [] {
                let path = roomPath(room), active = parent.selected == "room:\(room.id)"
                let color = room.name.contains("卫") || room.name.contains("厨") ? AppTheme.wetRoomUI : AppTheme.roomUI
                color.withAlphaComponent(parent.background ? 0.30 : 0.95).setFill(); path.fill()
                (active ? planTint : AppTheme.wallUI).setStroke(); path.lineWidth = active ? 3 : 2; path.lineJoinStyle = .round; path.stroke()
            }
            for f in plan.spatial?.furniture ?? [] { drawFurniture(f,context:context) }
            let lights = LightingAppearance.sources(board: parent.board, plan: plan, aspect: p.imageHeight / p.imageWidth)
            LightingAppearance.draw(lights, in: context, width: p.imageWidth * p.scale, project: screen)
            for room in plan.spatial?.rooms ?? [] { label(room.name,at:screen(room.center),size:10,color:UIColor.label,fill:AppTheme.surfaceUI.withAlphaComponent(0.95)) }
            let centers = deviceCenters()
            let iconSize: CGFloat = parent.embedded ? 28 : 36
            if parent.embedded {
                for device in parent.board.devices {
                    guard let point = plan.devices[device.id], let center = centers[device.id] else { continue }
                    let actual = screen(point)
                    if distance(actual,center) > 3 {
                        AppTheme.accentUI.withAlphaComponent(0.45).setStroke()
                        let line = UIBezierPath(); line.move(to:actual); line.addLine(to:center); line.lineWidth = 0.75; line.stroke()
                    }
                }
            }
            var statusRects: [CGRect] = parent.embedded ? parent.board.devices.compactMap { device in
                guard let point = plan.devices[device.id] else { return nil }
                let center = centers[device.id] ?? screen(point)
                return CGRect(x:center.x-iconSize/2-3,y:center.y-iconSize/2-3,width:iconSize+6,height:iconSize+6)
            } : []
            for device in parent.board.devices {
                guard let point = plan.devices[device.id] else { continue }
                let center = centers[device.id] ?? screen(point), active = parent.selected == "device:\(device.id)"
                let rect = CGRect(x:center.x-iconSize/2,y:center.y-iconSize/2,width:iconSize,height:iconSize)
                let state = parent.board.visualState(device)
                let key = device.icon + "|" + state.rawValue
                if icons[key] == nil { icons[key] = DeviceAppearance(state: state).image(symbol: device.icon) }
                icons[key]?.draw(in:rect)
                if active { planTint.setStroke(); let ring = UIBezierPath(ovalIn:rect.insetBy(dx:-2,dy:-2)); ring.lineWidth = 2; ring.stroke() }
                if !active && hoverName != "device:\(device.id)" && !parent.board.sensorSummary(device).isEmpty {
                    let summary = parent.board.sensorSummary(device)
                    let size = (summary as NSString).size(withAttributes:[.font:UIFont.systemFont(ofSize:9,weight:.semibold)])
                    var origin = CGPoint(x:center.x,y:center.y+iconSize/2+8)
                    var fits = false
                    for row in 0..<6 {
                        origin.y = center.y+iconSize/2+8+CGFloat(row)*16
                        let rect = CGRect(x:origin.x-size.width/2-5,y:origin.y-size.height/2-3,width:size.width+10,height:size.height+6)
                        if (!parent.embedded || view.bounds.insetBy(dx:4,dy:4).contains(rect)) && !statusRects.contains(where: { $0.intersects(rect) }) { statusRects.append(rect); fits = true; break }
                    }
                    if fits || !parent.embedded { label(summary,at:origin,size:9,color:planTint,fill:AppTheme.surfaceUI) }
                }
                if active || hoverName == "device:\(device.id)" { label("\(device.name) · \(parent.board.status(device))",at:CGPoint(x:center.x,y:center.y-28),size:11,color:planTint,fill:AppTheme.surfaceUI) }
            }
            if parent.editing, let id = parent.selected, let f = plan.spatial?.furniture.first(where:{ "furniture:\($0.id)" == id }) {
                let resize = furnitureHandle(f,rotate:false), rotate = furnitureHandle(f,rotate:true)
                let top = furnitureHandle(f,rotate:true,extra:0)
                planTint.setStroke(); let stem = UIBezierPath(); stem.move(to:top); stem.addLine(to:rotate); stem.lineWidth = 1.5; stem.stroke()
                handle(resize); handle(rotate)
                label("尺寸",at:CGPoint(x:resize.x,y:resize.y+14),size:9,color:planTint,fill:AppTheme.surfaceUI)
                label("旋转",at:CGPoint(x:rotate.x,y:rotate.y-13),size:9,color:planTint,fill:AppTheme.surfaceUI)
            }
            if parent.editing, let room = plan.spatial?.rooms.first(where:{ "room:\($0.id)" == parent.selected }) { for point in room.points { handle(screen(point)) } }
            if parent.editing, let snap = snapResult, snap.kind != .none {
                let at = screen(snap.point)
                context.saveGState(); context.setStrokeColor(planTint.withAlphaComponent(0.7).cgColor); context.setLineWidth(1); context.setLineDash(phase: 0, lengths: [5,4])
                if snap.alignX { context.move(to: CGPoint(x: at.x, y: 0)); context.addLine(to: CGPoint(x: at.x, y: view.bounds.height)) }
                if snap.alignY { context.move(to: CGPoint(x: 0, y: at.y)); context.addLine(to: CGPoint(x: view.bounds.width, y: at.y)) }
                context.strokePath(); context.setLineDash(phase: 0, lengths: [])
                context.strokeEllipse(in: CGRect(x: at.x-10, y: at.y-10, width: 20, height: 20)); context.restoreGState()
                label(snap.label, at: CGPoint(x: at.x, y: at.y-26), size: 11, color: planTint, fill: AppTheme.surfaceUI)
            }
            context.restoreGState()
        }
        func drawFurniture(_ f:SpatialFurniture,context:CGContext) {
            let p = projection, center = screen(f.point), w = max(4,f.width*p.imageWidth*p.scale), h = max(4,f.depth*p.imageHeight*p.scale)
            context.saveGState(); context.translateBy(x:center.x,y:center.y); context.rotate(by:f.rotation * .pi/180 + p.rotation)
            let rect = CGRect(x:-w/2,y:-h/2,width:w,height:h)
            if f.kind == "model" {
                if let asset = FurnitureLibrary.shared.asset(f.assetID), let image = FurnitureLibrary.shared.image(asset) { image.draw(in:rect) }
                else { UIColor.systemGray5.setFill(); UIBezierPath(rect:rect).fill(); label("模型缺失",at:.zero,size:10,color:.darkGray,fill:.white) }
                if parent.selected == "furniture:\(f.id)" { planTint.setStroke(); let outline = UIBezierPath(rect:rect.insetBy(dx:-3,dy:-3)); outline.lineWidth = 2; outline.stroke() }
                context.restoreGState(); return
            }
            let wood = UIColor(red:0.64,green:0.50,blue:0.35,alpha:1), fabric = UIColor(red:0.67,green:0.79,blue:0.74,alpha:1)
            func part(_ rect:CGRect,_ color:UIColor) { color.setFill(); UIBezierPath(roundedRect:rect,cornerRadius:2).fill() }
            if f.kind != "toilet" { part(rect,f.kind == "plant" ? planTint : f.kind == "sofa" ? fabric : f.kind == "sink" ? .white : wood) }
            switch f.kind {
            case "stove":
                part(rect,UIColor(white:0.22,alpha:1))
                for x in [-0.25,0.25] {
                    let r = min(w*0.18,h*0.30)
                    let ring = UIBezierPath(ovalIn:CGRect(x:w*x-r,y:-h*0.10-r,width:r*2,height:r*2))
                    UIColor.lightGray.setStroke(); ring.lineWidth = 2; ring.stroke()
                    UIColor.black.setFill(); UIBezierPath(ovalIn:CGRect(x:w*x-r*0.5,y:-h*0.10-r*0.5,width:r,height:r)).fill()
                    part(CGRect(x:w*x-w*0.025,y:h*0.30,width:w*0.05,height:h*0.08),.lightGray)
                }
            case "fridge":
                part(rect,UIColor(red:0.77,green:0.82,blue:0.84,alpha:1))
                part(rect.insetBy(dx:w*0.07,dy:h*0.07),UIColor(white:0.92,alpha:1))
                part(CGRect(x:-w*0.36,y:h*0.34,width:w*0.72,height:h*0.06),.gray)
                part(CGRect(x:-w*0.015,y:h*0.27,width:w*0.03,height:h*0.22),.gray)
            case "counter":
                part(rect,UIColor(red:0.91,green:0.89,blue:0.83,alpha:1))
                part(CGRect(x:-w/2,y:-h/2,width:w,height:h*0.10),.lightGray)
                for x in [-0.25,0.25] { part(CGRect(x:w*x-w*0.10,y:h*0.39,width:w*0.20,height:h*0.04),wood) }
            case "rangeHood":
                part(rect,UIColor(white:0.78,alpha:1))
                part(CGRect(x:-w*0.23,y:-h*0.45,width:w*0.46,height:h*0.52),UIColor(white:0.9,alpha:1))
                for y in [0.15,0.25,0.35] { part(CGRect(x:-w*0.37,y:h*y,width:w*0.74,height:h*0.025),.gray) }
            case "bed":
                part(rect.insetBy(dx:2,dy:2),.white)
                part(CGRect(x:-w/2+3,y:-h*0.10,width:max(1,w-6),height:h*0.56),fabric)
                for x in [-0.25,0.25] { part(CGRect(x:w*x-w*0.18,y:-h*0.40,width:w*0.36,height:h*0.20),UIColor(white:0.9,alpha:1)) }
            case "sofa":
                part(CGRect(x:-w/2+3,y:-h*0.3,width:max(1,w-6),height:h*0.65),UIColor(red:0.83,green:0.89,blue:0.85,alpha:1))
                context.setStrokeColor(fabric.cgColor); context.move(to:CGPoint(x:0,y:-h*0.3)); context.addLine(to:CGPoint(x:0,y:h*0.35)); context.strokePath()
            case "toilet":
                let ceramic = UIColor(red:0.90,green:0.94,blue:0.94,alpha:1)
                let bowl = UIBezierPath(ovalIn:CGRect(x:-w*0.43,y:-h*0.18,width:w*0.86,height:h*0.67))
                UIColor.white.setFill(); bowl.fill(); ceramic.setStroke(); bowl.lineWidth = 1; bowl.stroke()
                ceramic.setFill(); UIBezierPath(ovalIn:CGRect(x:-w*0.29,y:-h*0.07,width:w*0.58,height:h*0.42)).fill()
                part(CGRect(x:-w*0.46,y:-h*0.5,width:w*0.92,height:h*0.27),.white)
                part(CGRect(x:-w*0.10,y:-h*0.42,width:w*0.20,height:h*0.055),.lightGray)
            case "sink":
                let basin = CGRect(x:-w*0.35,y:-h*0.24,width:w*0.70,height:h*0.62)
                part(basin,UIColor(red:0.72,green:0.85,blue:0.87,alpha:1))
                part(CGRect(x:-w*0.045,y:-h*0.45,width:w*0.09,height:h*0.28),.gray)
                UIColor.darkGray.setFill(); UIBezierPath(ovalIn:CGRect(x:-w*0.035,y:h*0.08,width:w*0.07,height:w*0.07)).fill()
            case "bath": part(rect.insetBy(dx:3,dy:3),.white); part(rect.insetBy(dx:6,dy:6),UIColor(red:0.65,green:0.83,blue:0.86,alpha:1))
            case "plant": UIColor(red:0.39,green:0.61,blue:0.40,alpha:1).setFill(); UIBezierPath(ovalIn:rect.insetBy(dx:2,dy:2)).fill()
            case "cabinet": context.setStrokeColor(UIColor.white.withAlphaComponent(0.6).cgColor); context.move(to:CGPoint(x:0,y:-h/2)); context.addLine(to:CGPoint(x:0,y:h/2)); context.strokePath()
            default: break
            }
            if parent.selected == "furniture:\(f.id)" { planTint.setStroke(); let outline = UIBezierPath(rect:rect.insetBy(dx:-3,dy:-3)); outline.lineWidth = 2; outline.stroke() }
            context.restoreGState()
        }
        func handle(_ point:CGPoint) {
            let path = UIBezierPath(ovalIn:CGRect(x:point.x-6,y:point.y-6,width:12,height:12)); UIColor.white.setFill(); path.fill(); planTint.setStroke(); path.lineWidth = 2; path.stroke()
        }
        func label(_ text:String,at point:CGPoint,size:CGFloat,color:UIColor,fill:UIColor) {
            let attrs: [NSAttributedString.Key:Any] = [.font:UIFont.systemFont(ofSize:size,weight:.semibold),.foregroundColor:color]
            let textSize = (text as NSString).size(withAttributes:attrs)
            let rect = CGRect(x:point.x-textSize.width/2-4,y:point.y-textSize.height/2-2,width:textSize.width+8,height:textSize.height+4)
            fill.setFill(); UIBezierPath(roundedRect:rect,cornerRadius:4).fill()
            (text as NSString).draw(at:CGPoint(x:rect.minX+4,y:rect.minY+2),withAttributes:attrs)
        }
        func furnitureHandle(_ f:SpatialFurniture,rotate:Bool,extra:Double = 20) -> CGPoint {
            let p = projection, center = screen(f.point), w = f.width*p.imageWidth*p.scale, h = f.depth*p.imageHeight*p.scale
            let x = rotate ? 0 : w/2, y = rotate ? -h/2-extra : h/2, a = f.rotation * .pi/180 + p.rotation
            return CGPoint(x:center.x+x*cos(a)-y*sin(a),y:center.y+x*sin(a)+y*cos(a))
        }
        func distance(_ a:CGPoint,_ b:CGPoint) -> CGFloat { hypot(a.x-b.x,a.y-b.y) }
        func target(_ location:CGPoint) -> String? {
            let centers = deviceCenters()
            let nearest = parent.board.devices.compactMap { device -> (String,CGFloat)? in
                guard let p = plan.devices[device.id] else { return nil }; return ("device:\(device.id)",distance(centers[device.id] ?? screen(p),location))
            }.filter { $0.1 <= 20 }.min { $0.1 < $1.1 }
            if let nearest { return nearest.0 }
            if let f = plan.spatial?.furniture.reversed().first(where:{ projection.hits($0,x:location.x,y:location.y) }) { return "furniture:\(f.id)" }
            let raw = projection.rawPoint(x:location.x,y:location.y)
            guard (0...1).contains(raw.x), (0...1).contains(raw.y) else { return nil }
            let p = PlanPoint(x:raw.x,y:raw.y)
            return plan.spatial?.rooms.reversed().first(where:{ $0.contains(p) }).map { "room:\($0.id)" }
        }
        @objc func click(_ g:UITapGestureRecognizer) {
            let name = target(g.location(in:view)); parent.select(name); view?.setNeedsDisplay()
            if !parent.editing, let device = parent.board.devices.first(where:{ "device:\($0.id)" == name }) {
                let now = ProcessInfo.processInfo.systemUptime
                guard lastActivation?.id != device.id || now - (lastActivation?.time ?? 0) >= 0.45 else { return }
                lastActivation = (device.id, now)
                parent.activate?(device)
            }
        }
        @objc func doubleClick(_ g:UITapGestureRecognizer) {
            if let name = target(g.location(in:view)), let device = parent.board.devices.first(where:{ "device:\($0.id)" == name }) { parent.select(name); if !parent.editing, let activate = parent.activate { activate(device) } else { parent.open(device) } }
            else if target(g.location(in:view)) == nil { parent.viewport = PlanViewport(); view?.setNeedsDisplay() }
        }
        func gestureRecognizer(_ g:UIGestureRecognizer,shouldReceive touch:UITouch) -> Bool {
            if g.name == "plan-drag" { dragOrigin = touch.location(in:view) }
            return true
        }
        func gestureRecognizerShouldBegin(_ g:UIGestureRecognizer) -> Bool { if g.name == "plan-drag" { return !g.buttonMask.contains(.secondary) }; return baseline == nil }
        func gestureRecognizer(_ g:UIGestureRecognizer,shouldBeRequiredToFailBy other:UIGestureRecognizer) -> Bool {
            guard g.name == "plan-wheel" || g.name == "plan-drag" || (parent.embedded && g.name == "plan-pinch"),let view,let ancestor = other.view,ancestor !== view else { return false }
            return view.isDescendant(of:ancestor) && other is UIPanGestureRecognizer
        }
        func gestureRecognizer(_ g:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer) -> Bool {
            guard !parent.editing, g.view === other.view else { return false }
            return (g.name == "plan-drag" && other.name == "plan-pinch") || (g.name == "plan-pinch" && other.name == "plan-drag")
        }
        @objc func hover(_ g:UIHoverGestureRecognizer) {
            let inside = g.state != .ended && g.state != .cancelled; parent.hoverChanged(inside)
            let name = inside ? target(g.location(in:view)) : nil
            if name != hoverName { hoverName = name; view?.setNeedsDisplay() }
        }
        @objc func wheel(_ g:UIPanGestureRecognizer) {
            let delta = g.translation(in:view); g.setTranslation(.zero,in:view)
            let position = g.location(in:view)
            if g.modifierFlags.contains(.shift) { parent.viewport = projection.panned(dx:delta.x,dy:delta.y) }
            else { parent.viewport = projection.zoomed(factor:exp(max(-1,min(1,Double(delta.y)*0.0025))),aroundX:position.x,y:position.y) }
            view?.setNeedsDisplay()
        }
        @objc func pinch(_ g:UIPinchGestureRecognizer) {
            let at = g.location(in:view); parent.viewport = projection.zoomed(factor:g.scale,aroundX:at.x,y:at.y); g.scale = 1; view?.setNeedsDisplay()
        }
        @objc func drag(_ g:UIPanGestureRecognizer) {
            let at = g.location(in:view), translation = g.translation(in:view)
            if g.state == .began {
                action = "pan"; subject = nil; lastTranslation = .zero
                let start = dragOrigin ?? CGPoint(x:at.x-translation.x,y:at.y-translation.y)
                if parent.editing && !g.modifierFlags.contains(.shift) {
                    if let f = plan.spatial?.furniture.first(where:{ "furniture:\($0.id)" == parent.selected }),distance(start,furnitureHandle(f,rotate:true)) <= 18 { action = "rotate"; subject = f.id }
                    else if let f = plan.spatial?.furniture.first(where:{ "furniture:\($0.id)" == parent.selected }),distance(start,furnitureHandle(f,rotate:false)) <= 18 { action = "resize"; subject = f.id }
                    else if let room = plan.spatial?.rooms.first(where:{ "room:\($0.id)" == parent.selected }), let index = room.points.indices.first(where:{ distance(start,screen(room.points[$0])) <= 12 }) { action = "vertex"; subject = room.id; vertex = index }
                    else if let name = target(start), name.hasPrefix("device:") || name.hasPrefix("furniture:") {
                        action = "move"; subject = name; parent.select(name)
                        let id = String(name.split(separator:":",maxSplits:1)[1])
                        let p = plan.devices[id] ?? plan.spatial?.furniture.first(where:{ $0.id == id })?.point ?? point(start)
                        let center = screen(p); offset = CGPoint(x:center.x-start.x,y:center.y-start.y)
                    }
                }
                if action != "pan" { baseline = parent.board.plan; preview = baseline }
            }
            if action == "pan" {
                parent.viewport = projection.panned(dx:translation.x-lastTranslation.x,dy:translation.y-lastTranslation.y)
            } else if let subject {
                switch action {
                case "move":
                    let id = String(subject.split(separator:":",maxSplits:1)[1]), p = point(CGPoint(x:at.x+offset.x,y:at.y+offset.y))
                    if subject.hasPrefix("device:") { preview?.devices[id] = p }
                    else if let i = preview?.spatial?.furniture.firstIndex(where:{ $0.id == id }) { preview?.spatial?.furniture[i].point = p }
                case "resize", "rotate":
                    if let i = preview?.spatial?.furniture.firstIndex(where:{ $0.id == subject }), let original = baseline?.spatial?.furniture.first(where:{ $0.id == subject }) {
                        if action == "rotate" { let c = screen(original.point); preview?.spatial?.furniture[i].rotation = (atan2(at.y-c.y,at.x-c.x)+Double.pi/2)*180/Double.pi }
                        else { let local = projection.furnitureLocal(original,x:at.x,y:at.y); preview?.spatial?.furniture[i].width = min(1,max(0.005,2*local.x/(projection.imageWidth*projection.scale))); preview?.spatial?.furniture[i].depth = min(1,max(0.005,2*local.y/(projection.imageHeight*projection.scale))) }
                    }
                case "vertex": if let i = preview?.spatial?.rooms.firstIndex(where:{ $0.id == subject }) { preview?.spatial?.rooms[i].points[vertex] = point(at) }
                default: break
                }
            }
            lastTranslation = translation; view?.setNeedsDisplay()
            if g.state == .ended {
                if parent.editing, let edited = preview, let baseline, edited != baseline {
                    do {
                        guard baseline == parent.board.plan else { throw CommandFailure("layout_changed","布局已在其他位置修改，请重新调整。") }
                        try edited.spatial?.validate(); parent.board.checkpointLayout(); parent.board.plan = edited; parent.board.saveLayout()
                    } catch { parent.board.error = "调整未保存：\(error.localizedDescription)" }
                }
            }
            if [.ended,.cancelled,.failed].contains(g.state) { preview = nil; baseline = nil; snapResult = nil; action = ""; subject = nil; dragOrigin = nil; view?.setNeedsDisplay() }
        }
        func contextMenuInteraction(_ interaction:UIContextMenuInteraction,configurationForMenuAtLocation location:CGPoint) -> UIContextMenuConfiguration? {
            // Resolve visible vertex handles before room/device hit testing: a corner
            // lies on the polygon edge and may otherwise select the adjacent room.
            if parent.editing, baseline == nil,
               let room = plan.spatial?.rooms.first(where: { "room:\($0.id)" == parent.selected }),
               let index = room.points.indices.min(by: { distance(screen(room.points[$0]), location) < distance(screen(room.points[$1]), location) }),
               distance(screen(room.points[index]), location) <= 16 {
                return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                    let item = UIAction(title: room.points.count > 3 ? "删除此角点" : "至少保留 3 个角点", image: UIImage(systemName: "minus.circle"), attributes: room.points.count > 3 ? .destructive : .disabled) { _ in
                        guard let self, self.parent.editing, self.baseline == nil else { return }
                        self.parent.board.removeRoomVertex(room, at: index)
                        self.view?.setNeedsDisplay()
                    }
                    return UIMenu(title: "\(room.name) · 角点 \(index + 1)", children: [item])
                }
            }
            if parent.editing, baseline == nil,
               let room = plan.spatial?.rooms.first(where: { "room:\($0.id)" == parent.selected }) {
                let origin = screen(PlanPoint(x: 0, y: 0)), p = projection
                if let hit = room.nearestWall(x: location.x-origin.x, y: location.y-origin.y, width: p.imageWidth*p.scale, height: p.imageHeight*p.scale), hit.distance <= 12 {
                    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                        UIMenu(title: "\(room.name) · 墙体 \(hit.edge + 1)", children: [
                            UIAction(title: room.points.count < 100 ? "在此添加角点" : "已达 100 个角点上限", image: UIImage(systemName: "plus.circle"), attributes: room.points.count < 100 ? [] : .disabled) { _ in
                                guard let self, self.parent.editing, self.baseline == nil else { return }
                                self.parent.board.insertRoomVertex(room, on: hit.edge, fraction: hit.fraction)
                                self.view?.setNeedsDisplay()
                            }
                        ])
                    }
                }
            }
            let name = target(location), p = point(location); parent.select(name)
            return UIContextMenuConfiguration(identifier:nil,previewProvider:nil) { [weak self] _ in
                guard let self else { return nil }; var items: [UIMenuElement] = []
                if let d = self.parent.board.devices.first(where:{ "device:\($0.id)" == name }) {
                    items.append(UIAction(title:"打开设备控制") { _ in self.parent.open(d) })
                    if self.parent.editing { items.append(UIAction(title:"从布局移除") { _ in guard self.parent.editing else { return }; self.parent.board.checkpointLayout(); self.parent.board.unplace(d.id,room:false); self.parent.select(nil) }) }
                } else if self.parent.editing, let f = self.plan.spatial?.furniture.first(where:{ "furniture:\($0.id)" == name }) {
                    for degrees in [-15.0,15,90] { items.append(UIAction(title:"旋转 \(Int(degrees))°") { _ in self.rotate(f.id,by:degrees) }) }
                    items.append(UIAction(title:"移除家具") { _ in guard self.parent.editing else { return }; self.parent.board.checkpointLayout(); self.parent.board.plan.spatial?.furniture.removeAll { $0.id == f.id }; self.parent.board.saveLayout(); self.parent.select(nil) })
                } else if self.parent.editing {
                    items.append(UIMenu(title:"在此添加家具",children:SpatialFurniture.kinds.map { kind in UIAction(title:SpatialFurniture.title(kind)) { _ in guard self.parent.editing else { return }; self.parent.select(self.parent.board.addFurniture(kind,at:p)) } }))
                    let devices = self.parent.board.devices.filter { self.plan.devices[$0.id] == nil }
                    if !devices.isEmpty { items.append(UIMenu(title:"在此放入设备",children:devices.map { d in UIAction(title:"\(d.roomName) · \(d.name)") { _ in guard self.parent.editing else { return }; self.parent.board.checkpointLayout(); self.parent.board.place(d.id,room:false,at:p); self.parent.select("device:\(d.id)") } })) }
                }
                if self.parent.editing && !self.parent.board.layoutUndo.isEmpty { items.append(UIAction(title:"撤销布局修改") { _ in guard self.parent.editing else { return }; self.parent.board.undoLayout() }) }
                items.append(UIAction(title:"适合窗口") { _ in self.parent.viewport = PlanViewport(); self.view?.setNeedsDisplay() })
                return UIMenu(children:items)
            }
        }
        func rotate(_ id:String,by degrees:Double) {
            guard parent.editing, let i = parent.board.plan.spatial?.furniture.firstIndex(where:{ $0.id == id }) else { return }
            parent.board.checkpointLayout(); parent.board.plan.spatial?.furniture[i].rotation += degrees; parent.board.saveLayout()
        }
        @objc func libraryDrop(_ notification:Notification) {
            guard parent.editing, let view, let window = view.window, notification.object as? UIWindow === window,
                  let location = notification.userInfo?["point"] as? NSValue,
                  let payload = notification.userInfo?["payload"] as? String else { return }
            let at = view.convert(location.cgPointValue,from:window)
            guard view.bounds.contains(at) else { return }
            let position = point(at)
            if payload.hasPrefix("home-model:"), let asset = FurnitureLibrary.shared.asset(String(payload.dropFirst("home-model:".count))) { parent.select(parent.board.addModel(asset,at:position)) }
            else if payload.hasPrefix("home-furniture:") {
                let kind = String(payload.dropFirst("home-furniture:".count))
                if SpatialFurniture.kinds.contains(kind) { parent.select(parent.board.addFurniture(kind,at:position)) }
            }
        }
        func dropInteraction(_ interaction:UIDropInteraction,canHandle session:UIDropSession) -> Bool { parent.editing && session.canLoadObjects(ofClass:NSString.self) }
        func dropInteraction(_ interaction:UIDropInteraction,sessionDidUpdate session:UIDropSession) -> UIDropProposal { UIDropProposal(operation:parent.editing ? .copy : .forbidden) }
        func dropInteraction(_ interaction:UIDropInteraction,performDrop session:UIDropSession) {
            guard parent.editing, let view else { return }; let at = point(session.location(in:view))
            session.loadObjects(ofClass:NSString.self) { [weak self] values in Task { @MainActor in
                guard let self, self.parent.editing, let value = values.first as? String else { return }
                if let device = self.parent.board.devices.first(where:{ "home-device:\($0.id)" == value }) { self.parent.board.checkpointLayout(); self.parent.board.place(device.id,room:false,at:at); self.parent.select("device:\(device.id)") }
                else if value.hasPrefix("home-model:"), let asset = FurnitureLibrary.shared.asset(String(value.dropFirst("home-model:".count))) { self.parent.select(self.parent.board.addModel(asset,at:at)) }
                else if value.hasPrefix("home-furniture:") { let kind = String(value.dropFirst("home-furniture:".count)); if SpatialFurniture.kinds.contains(kind) { self.parent.select(self.parent.board.addFurniture(kind,at:at)) } }
            } }
        }
    }
}
