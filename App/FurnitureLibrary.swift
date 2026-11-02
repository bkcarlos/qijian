import SwiftUI
import SceneKit
import UniformTypeIdentifiers

@MainActor
final class FurnitureLibrary: ObservableObject {
    static let shared = FurnitureLibrary()
    @Published private(set) var assets: [FurnitureAsset] = []
    @Published private(set) var hidden = Set(UserDefaults.standard.stringArray(forKey:"furniture.hidden") ?? [])
    @Published private(set) var importing = false
    @Published var message: String?
    private let nodes = NSCache<NSString, SCNNode>()
    private let images = NSCache<NSString, UIImage>()
    private let bundled = Bundle.main.resourceURL!.appendingPathComponent("Furniture",isDirectory:true)
    private let custom = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("FurnitureLibrary",isDirectory:true)
    private var customManifest: URL { custom.appendingPathComponent("catalog.json") }
    init() {
        nodes.countLimit = 30; images.countLimit = 180
        do {
            assets = try JSONDecoder().decode([FurnitureAsset].self,from:Data(contentsOf:bundled.appendingPathComponent("catalog.json")))
            if FileManager.default.fileExists(atPath:customManifest.path) {
                assets += try JSONDecoder().decode([FurnitureAsset].self,from:Data(contentsOf:customManifest))
            }
        } catch { message = "素材库读取失败：\(error.localizedDescription)" }
    }
    func asset(_ id: String?) -> FurnitureAsset? { assets.first { $0.id == id } }
    func title(_ f: SpatialFurniture) -> String { asset(f.assetID)?.title ?? (f.kind == "model" ? "未找到模型" : SpatialFurniture.title(f.kind)) }
    func url(_ asset: FurnitureAsset, _ path: String) -> URL { (asset.isCustom ? custom : bundled).appendingPathComponent(path) }
    func image(_ asset: FurnitureAsset, thumbnail: Bool = false) -> UIImage? {
        let key = asset.id + (thumbnail ? ":thumb" : ":top")
        if let image = images.object(forKey:key as NSString) { return image }
        let top = url(asset,asset.preview)
        let thumb = top.deletingPathExtension().appendingPathExtension("png").deletingLastPathComponent().appendingPathComponent(top.deletingPathExtension().lastPathComponent+"-thumb.png")
        guard let image = UIImage(contentsOfFile:(thumbnail && FileManager.default.fileExists(atPath:thumb.path) ? thumb : top).path) else { return nil }
        images.setObject(image,forKey:key as NSString); return image
    }
    func node(_ asset: FurnitureAsset, width: CGFloat, depth: CGFloat) -> SCNNode? {
        let original: SCNNode
        if let cached = nodes.object(forKey:asset.id as NSString) { original = cached }
        else {
            do { original = try FurnitureModelLoader.load(url(asset,asset.file)); nodes.setObject(original,forKey:asset.id as NSString) }
            catch { return nil }
        }
        let copy = original.clone(), (a,b) = original.boundingBox
        let sx = Float(width)/(b.x-a.x), sz = Float(depth)/(b.z-a.z)
        let root = SCNNode(); copy.scale = SCNVector3(sx,sqrt(sx*sz),sz)
        copy.position = SCNVector3(-(a.x+b.x)/2*sx,-a.y*sqrt(sx*sz),-(a.z+b.z)/2*sz)
        root.addChildNode(copy); return root
    }
    func setHidden(_ asset: FurnitureAsset, _ value: Bool) {
        guard asset.isCustom else { return }
        if value { hidden.insert(asset.id) } else { hidden.remove(asset.id) }
        UserDefaults.standard.set(Array(hidden),forKey:"furniture.hidden")
    }
    func registerCloudModels(_ incoming: [FurnitureAsset]) throws {
        let known = assets.filter(\.isCustom)
        for item in incoming {
            if let old = assets.first(where: { $0.id == item.id }), old != item {
                throw CommandFailure("cloud_model_collision", "同一模型标识对应不同内容，未覆盖本地模型")
            }
        }
        let additions = incoming.filter { item in !assets.contains(where: { $0.id == item.id }) }
        try JSONEncoder().encode(known + additions).write(to: customManifest, options: .atomic)
        assets += additions
    }
    func importModels(_ urls: [URL]) async {
        guard !importing else { return }; importing = true; message = nil
        let access = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { access.forEach { $0.stopAccessingSecurityScopedResource() }; importing = false }
        do {
            let root = custom
            let added = try await Task.detached(priority:.userInitiated) { try FurnitureModelLoader.importFiles(urls,to:root) }.value
            let updated = assets.filter(\.isCustom) + added
            do { try JSONEncoder().encode(updated).write(to:customManifest,options:.atomic) }
            catch { if let file = added.first?.file { try? FileManager.default.removeItem(at:custom.appendingPathComponent(file).deletingLastPathComponent()) }; throw error }
            assets += added; message = "已导入 \(added.count) 个模型，在“我的模型”中选择并放入布局。"
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }
}

/// Loads static geometry and creates previews without changing the live home or layout.
enum FurnitureModelLoader {
    static func load(_ url: URL) throws -> SCNNode {
        let scene = try SCNScene(url:url,options:[.checkConsistency:true])
        let root = SCNNode(); scene.rootNode.childNodes.forEach { root.addChildNode($0) }
        var vertices = 0, count = 0
        root.enumerateChildNodes { node,_ in
            count += 1; vertices += node.geometry?.sources(for:.vertex).first?.vectorCount ?? 0
            node.camera = nil; node.light = nil; node.physicsBody = nil; node.constraints = nil; node.name = nil; node.removeAllAnimations()
        }
        let (a,b) = root.boundingBox
        let dimensions = [b.x-a.x,b.y-a.y,b.z-a.z]
        guard vertices > 0, vertices <= 500_000, count <= 5_000,
              dimensions.allSatisfy({ $0.isFinite && $0 > 0.00001 && $0 < 100_000 }) else {
            throw CommandFailure("invalid_model","模型须包含有效的立体网格，且顶点数不超过 50 万。")
        }
        return root
    }
    static func preview(_ original: SCNNode, top: Bool) -> UIImage {
        let scene = SCNScene(), model = original.clone(), (a,b) = original.boundingBox
        let w = b.x-a.x, h = b.y-a.y, d = b.z-a.z, span = max(w,h,d)
        model.position = SCNVector3(-(a.x+b.x)/2,-a.y,-(a.z+b.z)/2); scene.rootNode.addChildNode(model)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient; ambient.light!.intensity = 700; scene.rootNode.addChildNode(ambient)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light!.type = .directional; sun.light!.intensity = 600; sun.eulerAngles = SCNVector3(-Float.pi/3,-Float.pi/4,0); scene.rootNode.addChildNode(sun)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera!.usesOrthographicProjection = true; camera.camera!.zNear = 0.001; camera.camera!.zFar = Double(span*20+10)
        let size: CGSize
        if top {
            camera.position = SCNVector3(0,h+span*3,0); camera.eulerAngles.x = -.pi/2
            camera.camera!.orthographicScale = Double(d)/2
            let ratio = CGFloat(w/d); size = CGSize(width:ratio>=1 ? 256 : max(1,256*ratio),height:ratio>=1 ? max(1,256/ratio) : 256)
        } else {
            camera.position = SCNVector3(span*2,h+span*2,span*2); camera.look(at:SCNVector3(0,h/2,0)); camera.camera!.orthographicScale = Double(span)*0.85
            size = CGSize(width:256,height:256)
        }
        scene.rootNode.addChildNode(camera); scene.background.contents = UIColor.clear
        let renderer = SCNRenderer(device:nil,options:nil); renderer.scene = scene; renderer.pointOfView = camera
        return renderer.snapshot(atTime:0,with:size,antialiasingMode:.multisampling4X)
    }
    static func importFiles(_ urls: [URL], to root: URL) throws -> [FurnitureAsset] {
        let fm = FileManager.default
        guard !urls.isEmpty, urls.count <= 100 else { throw CommandFailure("model_limit","每次最多选择 100 个模型和配套文件。") }
        let models = urls.filter { ["obj","usdz"].contains($0.pathExtension.lowercased()) }
        guard !models.isEmpty else { throw CommandFailure("model_format","请选择 USDZ 或 OBJ 模型；OBJ 的 MTL 和贴图请一起选择。") }
        let folder = UUID().uuidString
        let destination = root.appendingPathComponent(folder,isDirectory:true)
        try fm.createDirectory(at:destination,withIntermediateDirectories:true)
        do {
            var total = 0, names = Set<String>()
            for url in urls {
                let properties = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                      ["obj","usdz","mtl","png","jpg","jpeg"].contains(url.pathExtension.lowercased()),
                      names.insert(url.lastPathComponent.lowercased()).inserted else { throw CommandFailure("model_files","文件类型不支持或存在重名文件，请分批导入。") }
                total += properties.fileSize ?? 0
                guard total <= 100_000_000 else { throw CommandFailure("model_size","一次导入的模型和贴图合计不能超过 100 MB。") }
                try fm.copyItem(at:url,to:destination.appendingPathComponent(url.lastPathComponent))
            }
            // OBJ/MTL dependencies must be selected local files, never paths outside this import.
            for url in urls where ["obj","mtl"].contains(url.pathExtension.lowercased()) {
                let text = try String(contentsOf:destination.appendingPathComponent(url.lastPathComponent),encoding:.utf8)
                for line in text.components(separatedBy:.newlines) {
                    let parts = line.split(whereSeparator: { $0.isWhitespace })
                    guard let command = parts.first, command == "mtllib" || command.hasPrefix("map_") || command == "bump" else { continue }
                    let reference = parts.dropFirst().joined(separator:" ")
                    guard !reference.isEmpty, !reference.contains("/"), !reference.contains("\\"), !reference.contains(":"), reference != "..",
                          fm.fileExists(atPath:destination.appendingPathComponent(reference).path) else {
                        throw CommandFailure("model_dependency","缺少或不支持的引用：\(reference)。请将 OBJ、MTL 和贴图放在同一目录并一起选择；复杂模型建议导出为 USDZ。")
                    }
                }
            }
            var results: [FurnitureAsset] = []
            for url in models {
                let id = UUID().uuidString, filename = url.lastPathComponent
                let node = try load(destination.appendingPathComponent(filename)), (a,b) = node.boundingBox
                let w = Double(b.x-a.x), d = Double(b.z-a.z), scale = min(1,2/max(w,d))
                let png = id+".png"
                guard let top = preview(node,top:true).pngData(), let thumb = preview(node,top:false).pngData() else { throw CommandFailure("model_preview","无法生成模型预览。") }
                try top.write(to:destination.appendingPathComponent(png),options:.atomic)
                try thumb.write(to:destination.appendingPathComponent(id+"-thumb.png"),options:.atomic)
                results.append(FurnitureAsset(id:"custom:"+id,title:url.deletingPathExtension().lastPathComponent,category:"我的模型",file:folder+"/"+filename,preview:folder+"/"+png,width:max(0.06,w*scale),depth:max(0.06,d*scale),keywords:filename))
            }
            return results
        } catch { try? fm.removeItem(at:destination); throw error }
    }
}
