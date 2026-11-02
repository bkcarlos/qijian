import SwiftUI
import CloudKit

struct StoredLayoutBundle: Codable { var layout: FloorPlanLayout; var image: Data? }

extension HomeBoardModel {
    func cloudDocument() throws -> CloudLayoutDocument {
        var document = CloudLayoutDocument(layout: plan, homeName: home?.name ?? "我的家", rooms: rooms, devices: devices, image: planImage?.jpegData(compressionQuality: 0.92))
        let library = FurnitureLibrary.shared
        let ids = Set(plan.spatial?.furniture.compactMap(\.assetID) ?? [])
        for id in ids where id.hasPrefix("custom:") {
            guard let asset = library.asset(id) else { throw CommandFailure("cloud_model", "缺少模型 \(id)，请先恢复模型文件") }
            document.models.append(asset)
            let folder = library.url(asset, asset.file).deletingLastPathComponent()
            var pending = [URL(fileURLWithPath: asset.file).lastPathComponent, URL(fileURLWithPath: asset.preview).lastPathComponent]
            var seen = Set<String>()
            while let name = pending.popLast() {
                guard seen.insert(name).inserted else { continue }
                guard !name.contains("/"), !name.contains("\\"), !name.contains(":"), name != ".." else { throw CommandFailure("cloud_model", "模型引用的文件路径不受支持") }
                let url = folder.appendingPathComponent(name)
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                      (properties.fileSize ?? Int.max) <= 100_000_000 else { throw CommandFailure("cloud_model", "模型文件无效或过大") }
                let bytes = try Data(contentsOf: url)
                document.files[folder.lastPathComponent + "/" + name] = bytes
                if ["obj", "mtl"].contains(url.pathExtension.lowercased()), let text = String(data: bytes, encoding: .utf8) {
                    for line in text.components(separatedBy: .newlines) {
                        let words = line.split(whereSeparator: \.isWhitespace)
                        guard let command = words.first, command == "mtllib" || command.hasPrefix("map_") || command == "bump" else { continue }
                        pending.append(words.dropFirst().joined(separator: " "))
                    }
                }
            }
        }
        try document.validate(); return document
    }
    func backupCloudConflict(record: CKRecord?) throws {
        let folder = try planDirectory().appendingPathComponent("CloudBackups/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(StoredLayoutBundle(layout: plan, image: planImage?.jpegData(compressionQuality: 0.92))).write(to: folder.appendingPathComponent("local.json"), options: .atomic)
        if let file = (record?["payload"] as? CKAsset)?.fileURL { try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("cloud.json")) }
    }
    func applyCloudDocument(_ document: CloudLayoutDocument, shared: Bool) throws {
        try document.validate()
        let (layout, missing) = document.mapped(homeID: homeID, rooms: rooms, devices: devices)
        let data = try JSONEncoder().encode(layout)
        _ = try FloorPlanLayout.decode(data, homeID: homeID)
        let image: UIImage?
        if let data = document.image {
            guard let decoded = UIImage(data: data), decoded.size.width > 0, decoded.size.height > 0,
                  decoded.size.width <= 8192, decoded.size.height <= 8192 else { throw CommandFailure("cloud_image", "共享底图无效或过大") }
            image = decoded
        } else { image = nil }
        // Validate/copy assets before switching the visible layout. A single atomic bundle is authoritative.
        try FurnitureLibrary.shared.installCloudModels(document)
        try backupCloudConflict(record: nil)
        let bundle = StoredLayoutBundle(layout: layout, image: document.image)
        try JSONEncoder().encode(bundle).write(to: planDirectory().appendingPathComponent("layout-bundle.json"), options: .atomic)
        installingCloudLayout = true
        plan = layout; planImage = image; layoutUndo = []
        installingCloudLayout = false
        notice = missing == 0 ? "布局已同步" : "布局已同步；\(missing) 个设备未能唯一匹配到此家庭，未创建控制入口。"
    }
}

extension FurnitureLibrary {
    func installCloudModels(_ document: CloudLayoutDocument) throws {
        try document.validate()
        guard !document.models.isEmpty else { return }
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FurnitureLibrary")
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for (path, bytes) in document.files {
            let destination = staging.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination, options: .atomic)
        }
        // Reject external OBJ/MTL dependencies before SceneKit is allowed to read them.
        for path in document.files.keys where ["obj", "mtl"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            guard let text = String(data: document.files[path]!, encoding: .utf8) else { throw CommandFailure("cloud_model", "模型文本编码不受支持") }
            for line in text.components(separatedBy: .newlines) {
                let words = line.split(whereSeparator: \.isWhitespace)
                guard let command = words.first, command == "mtllib" || command.hasPrefix("map_") || command == "bump" else { continue }
                let name = words.dropFirst().joined(separator: " ")
                let key = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent + "/" + name
                guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(":"), name != "..", document.files[key] != nil else { throw CommandFailure("cloud_model", "共享模型引用了包外文件") }
            }
        }
        for model in document.models {
            guard ["obj", "usdz"].contains(URL(fileURLWithPath: model.file).pathExtension.lowercased()) else { throw CommandFailure("cloud_model", "仅支持静态 OBJ 或 USDZ 模型") }
            _ = try FurnitureModelLoader.load(staging.appendingPathComponent(model.file))
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // UUID-named directories are immutable. Never replace a different local import with a shared file.
        for (path, bytes) in document.files {
            let destination = root.appendingPathComponent(path)
            if fm.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == bytes else { throw CommandFailure("cloud_model_collision", "本地与共享模型文件不同，已保留本地文件") }
            }
        }
        for (path, bytes) in document.files {
            let destination = root.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: destination.path) { try bytes.write(to: destination, options: .atomic) }
        }
        try registerCloudModels(document.models)
    }
}
