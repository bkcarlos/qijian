import SwiftUI
import CloudKit
import Combine

struct CloudLayoutBinding: Codable {
    var enabled = false
    var shared = false
    var zone = "HomeLayouts"
    var owner = CKCurrentUserDefaultName
    var record = ""
    var account: String?
    var revision: String?
    var dirty = false
    var generation = UUID().uuidString
    var lastSync: Date?
    var inventoryFingerprint: String?
    var id: CKRecord.ID { CKRecord.ID(recordName: record, zoneID: CKRecordZone.ID(zoneName: zone, ownerName: owner)) }
}
struct CloudLayoutInvitation: Identifiable, Codable {
    var id: String { owner + "/" + zone + "/" + record }
    var name: String
    var owner: String
    var zone: String
    var record: String
    var account: String
}
struct CloudLayoutShare: Identifiable { let id = UUID(); let share: CKShare; let container: CKContainer; var management = false }

@MainActor final class LayoutCloudSync: ObservableObject {
    static let containerID = "iCloud.com.carlosbk.homekitreadonly"
    static let invitationChanged = Notification.Name("layoutCloudInvitationChanged")
    private(set) lazy var container = CKContainer(identifier: Self.containerID)
    weak var board: HomeBoardModel?
    @Published private(set) var binding = CloudLayoutBinding()
    @Published private(set) var status = "尚未启用"
    @Published private(set) var busy = false
    @Published private(set) var conflict = false
    @Published private(set) var diagnostics = ""
    private var nextAttempt = Date.distantPast
    private var failures = 0
    @Published private(set) var invitations: [CloudLayoutInvitation] = []
    @Published private(set) var ownedLayouts: [CloudLayoutInvitation] = []
    @Published var shareSheet: CloudLayoutShare?
    private var remoteConflict: CKRecord?
    private var conflictGeneration = ""
    private var task: Task<Void, Never>?
    private var homeID = ""
    private var epoch = UUID()
    private var accountValidated = false
    private var zoneReady = false
    private var cancellables = Set<AnyCancellable>()
    var editable: Bool { !binding.shared && !busy && !conflict }
    var isShared: Bool { binding.shared }
    private var database: CKDatabase { binding.shared ? container.sharedCloudDatabase : container.privateCloudDatabase }
    private var stateURL: URL? { try? board?.planDirectory().appendingPathComponent("cloud-state.json") }

    init() {
        NotificationCenter.default.publisher(for: Self.invitationChanged).receive(on: RunLoop.main).sink { [weak self] _ in self?.loadInvitations() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .CKAccountChanged).receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }; self.epoch = UUID(); self.accountValidated = false; self.busy = false; self.zoneReady = false
            self.status = "iCloud 账号已变化，请重新检查连接"; self.conflict = false
        }.store(in: &cancellables)
        loadInvitations()
    }
    func selectHome(_ id: String) {
        task?.cancel(); epoch = UUID(); homeID = id; remoteConflict = nil; conflict = false; busy = false; accountValidated = false; zoneReady = false
        ownedLayouts = []
        let family = board?.layoutSource == .family
        binding = CloudLayoutBinding(shared: family, record: family ? "" : "layout-" + id)
        if let url = stateURL, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(CloudLayoutBinding.self, from: data), saved.shared == family { binding = saved }
        nextAttempt = .distantPast; failures = 0; diagnostics = ""
        status = binding.enabled ? "等待同步" : "尚未启用"
        if binding.shared { status = binding.record.isEmpty ? "请选择可用的家庭布局；首次使用需创建者授权" : "家庭布局 · 只读" }
    }
    private func persist() throws {
        guard let url = stateURL else { throw CommandFailure("cloud_home", "请先选择家庭") }
        try JSONEncoder().encode(binding).write(to: url, options: .atomic)
    }
    func localChanged() throws {
        guard !binding.shared else { throw CommandFailure("layout_readonly", "这是共享布局，只有创建者可以编辑") }
        binding.dirty = true; binding.generation = UUID().uuidString; try persist()
        guard binding.enabled else { return }
        status = "修改已保存，等待上传"
        task?.cancel(); task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            await self?.sync()
        }
    }
    func enable() async {
        guard !homeID.isEmpty, !binding.record.isEmpty else { return }
        binding.enabled = true
        // An initial nonempty local layout must not silently replace an existing cloud layout.
        if binding.revision == nil { binding.dirty = false }
        do { try persist() } catch { status = error.localizedDescription; return }
        await sync(manual: true)
        if !binding.shared && !hasLayout { await discoverOwnedLayouts() }
    }
    func pause() {
        guard !busy else { return }
        task?.cancel(); binding.enabled = false
        do { try persist(); status = "同步已暂停；本地布局保留" } catch { status = error.localizedDescription }
    }
    private func checkAccount() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CommandFailure("icloud_account", "请在系统设置登录 iCloud 并启用 iCloud 云盘") }
        let id = try await container.userRecordID().recordName
        if let expected = binding.account, expected != id { throw CommandFailure("icloud_changed", "iCloud 账号与此布局的同步账号不同。请切回原账号；不会上传或覆盖布局。") }
        return id
    }
    private func current(_ token: UUID) throws {
        guard token == epoch, !Task.isCancelled else { throw CancellationError() }
    }
    func sync(manual: Bool = false) async {
        guard manual || Date() >= nextAttempt else { return }
        guard binding.enabled, !binding.record.isEmpty, !busy, !conflict, !homeID.isEmpty, let board, board.layoutStorageReady, !board.layoutEditing else { return }
        #if targetEnvironment(simulator) && DEBUG
        if board.app.home.isDemo { status = "演示家庭不上传 iCloud"; return }
        #endif
        busy = true; status = "正在同步…"; let token = epoch
        defer { if token == epoch { busy = false } }
        do {
            let account = try await checkAccount(); try current(token)
            binding.account = account; accountValidated = true; try persist()
            let db = database
            if !binding.shared && !zoneReady {
                do { _ = try await db.recordZone(for: binding.id.zoneID) }
                catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                    _ = try await db.save(CKRecordZone(zoneID: binding.id.zoneID))
                }
                try current(token); zoneReady = true
            }
            let record: CKRecord?
            do { record = try await db.record(for: binding.id) }
            catch let error as CKError where error.code == .unknownItem { record = nil }
            try current(token)
            if let record {
                guard record["schema"] as? Int == 1, record["revision"] is String else { throw CommandFailure("cloud_schema", "云端布局版本不受支持，请更新 App") }
            }
            if binding.shared {
                guard let record else { throw CommandFailure("share_removed", "共享已停止或布局不可访问。保留的本地副本仍为只读。") }
                if binding.revision != record["revision"] as? String || binding.inventoryFingerprint != inventoryFingerprint { try apply(record) }
                binding.lastSync = Date(); try persist(); failures = 0; diagnostics = ""; nextAttempt = .distantPast; status = "成员只读 · 已同步"; return
            }
            let remote = record?["revision"] as? String
            let hasLocal = hasLayout
            // A cancelled successful upload can be recognized by its persisted generation.
            if let record, record["writerGeneration"] as? String == binding.generation {
                binding.revision = remote; binding.dirty = false
            }
            switch CloudLayoutDecision.resolve(base: binding.revision, remote: remote, dirty: binding.dirty, hasLocal: hasLocal) {
            case .upload: try await upload(record, token: token)
            case .download: if let record { try apply(record) }
            case .unchanged: break
            case .conflict:
                remoteConflict = record; conflictGeneration = binding.generation; conflict = true
                status = record == nil ? "云端布局已移除，需确认是否重新上传" : "本地与 iCloud 均有布局，请选择保留版本"
                return
            }
            try current(token); binding.lastSync = Date(); try persist(); failures = 0; diagnostics = ""; nextAttempt = .distantPast; status = hasLayout ? "已同步" : "已连接 iCloud，尚无布局。可连接其他设备已有布局。"
        } catch is CancellationError { }
        catch {
            if token == epoch {
                failures += 1
                let retry = (error as? CKError)?.retryAfterSeconds ?? min(300, pow(2, Double(min(failures, 4))) * 15)
                nextAttempt = Date().addingTimeInterval(max(15, retry))
                diagnostics = String(describing: error)
                if let error = error as? CKError, error.code == .serverRejectedRequest {
                    status = "iCloud 拒绝了本次请求，尚未同步。可以稍后重试，或检查 CloudKit 容器配置。"
                } else { status = "同步未完成：" + error.localizedDescription }
            }
        }
    }
    private func upload(_ existing: CKRecord?, token: UUID) async throws {
        guard !binding.shared, let board else { throw CommandFailure("layout_readonly", "成员无法上传共享布局") }
        let payload = try board.cloudDocument()
        let data = try JSONEncoder().encode(payload); _ = try CloudLayoutDocument.decode(data)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: temp, options: .atomic); defer { try? FileManager.default.removeItem(at: temp) }
        let record = existing ?? CKRecord(recordType: "HomeLayout", recordID: binding.id)
        let revision = UUID().uuidString, generation = binding.generation
        record["payload"] = CKAsset(fileURL: temp); record["revision"] = revision as CKRecordValue
        record["writerGeneration"] = generation as CKRecordValue
        record["title"] = payload.homeName as CKRecordValue; record["schema"] = 1 as CKRecordValue
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        for saved in result.saveResults.values { _ = try saved.get() }
        try current(token)
        binding.revision = revision; binding.dirty = binding.generation != generation; try persist()
    }
    private func apply(_ record: CKRecord) throws {
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL,
              let revision = record["revision"] as? String else { throw CommandFailure("cloud_payload", "云端布局不完整，请更新 App 或重试") }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 150_000_000 else { throw CommandFailure("cloud_size", "云端布局过大") }
        let document = try CloudLayoutDocument.decode(Data(contentsOf: url))
        try board?.applyCloudDocument(document, shared: binding.shared)
        binding.revision = revision; binding.dirty = false; binding.inventoryFingerprint = inventoryFingerprint; try persist()
    }
    func resolve(useLocal: Bool) async {
        guard conflict, !busy, !binding.shared else { return }
        let record = remoteConflict, token = epoch; busy = true
        defer { if token == epoch { busy = false } }
        do {
            _ = try await checkAccount(); try current(token)
            guard conflictGeneration == binding.generation else { throw CommandFailure("layout_changed", "布局已改变，请重新检查同步") }
            // Save both candidates before resolving. The upload still uses the original server change tag.
            try board?.backupCloudConflict(record: record)
            if useLocal { try await upload(record, token: token) }
            else { guard let record else { throw CommandFailure("cloud_missing", "云端没有可用布局") }; try apply(record) }
            try current(token); conflict = false; remoteConflict = nil; binding.lastSync = Date(); try persist(); status = "已同步"
        } catch { status = "处理未完成：" + error.localizedDescription; conflict = false; remoteConflict = nil }
    }
    func prepareShare(management: Bool = false) async {
        await sync(manual: true)
        guard binding.enabled, !binding.shared, !binding.dirty, !conflict, !busy, binding.revision != nil, accountValidated else { return }
        busy = true; let token = epoch
        defer { if token == epoch { busy = false } }
        do {
            _ = try await checkAccount(); try current(token)
            let root = try await database.record(for: binding.id); try current(token)
            var share: CKShare
            if let id = root.share?.recordID {
                guard let existing = try await database.record(for: id) as? CKShare else { throw CommandFailure("cloud_share", "共享记录无效") }
                share = existing
                share.publicPermission = .none
                for participant in share.participants where participant.role != .owner { participant.permission = .readOnly }
                let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                for value in result.saveResults.values { if let saved = try value.get() as? CKShare { share = saved } }
            }
            else {
                share = CKShare(rootRecord: root); share.publicPermission = .none
                share[CKShare.SystemFieldKey.title] = (board?.home?.name ?? "我的家") + " · 户型布局" as CKRecordValue
                let result = try await database.modifyRecords(saving: [root, share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                for value in result.saveResults.values { if let saved = try value.get() as? CKShare { share = saved } }
            }
            try current(token)
            shareSheet = CloudLayoutShare(share: share, container: container, management: management)
        } catch { if token == epoch { status = "无法创建共享：" + error.localizedDescription } }
    }
    private var inventoryFingerprint: String {
        guard let board else { return "" }
        return (board.devices.map { "\($0.id)|\($0.name)|\($0.roomName)" } + board.rooms.map { "\($0.id)|\($0.name)" }).sorted().joined(separator: "\n")
    }
    private var hasLayout: Bool {
        guard let board else { return false }
        return board.plan.spatial != nil || board.planImage != nil || !board.plan.devices.isEmpty
    }

    // HomeKit identifiers are device-local. Explicitly bind the same private record
    // across devices instead of assuming that the local HMHome UUID is portable.
    func discoverOwnedLayouts() async {
        guard !busy, !homeID.isEmpty, !binding.shared else { return }
        busy = true; let token = epoch
        defer { if token == epoch { busy = false } }
        do {
            let account = try await checkAccount(); try current(token)
            let db = container.privateCloudDatabase
            let zone = CKRecordZone.ID(zoneName: "HomeLayouts", ownerName: CKCurrentUserDefaultName)
            var cursor: CKServerChangeToken?, more = true
            var found: [String: CloudLayoutInvitation] = [:]
            while more {
                let changes = try await db.recordZoneChanges(inZoneWith: zone, since: cursor, desiredKeys: ["title", "schema"], resultsLimit: 100)
                try current(token)
                for (_, result) in changes.modificationResultsByID {
                    let record = try result.get().record
                    guard record.recordType == "HomeLayout", record["schema"] as? Int == 1, record.recordID != binding.id else { continue }
                    let item = CloudLayoutInvitation(name: record["title"] as? String ?? "我的布局", owner: zone.ownerName, zone: zone.zoneName, record: record.recordID.recordName, account: account)
                    found[item.id] = item
                }
                for deletion in changes.deletions { found.removeValue(forKey: zone.ownerName + "/" + zone.zoneName + "/" + deletion.recordID.recordName) }
                cursor = changes.changeToken; more = changes.moreComing
            }
            ownedLayouts = found.values.sorted { ($0.name, $0.record) < ($1.name, $1.record) }
            status = ownedLayouts.isEmpty ? "未找到其他布局。请先在有户型的设备上启用同步。" : "找到 \(ownedLayouts.count) 份我的布局，请选择连接到当前家庭"
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            if token == epoch { ownedLayouts = []; status = "尚无云端布局，请先在有户型的设备上启用同步。" }
        } catch { if token == epoch { status = "查找我的布局失败：" + error.localizedDescription } }
    }

    func useOwnedLayout(_ item: CloudLayoutInvitation) async {
        guard !busy, !homeID.isEmpty, !binding.shared, board?.layoutEditing == false else { return }
        busy = true; let token = epoch
        defer { if token == epoch { busy = false } }
        do {
            let account = try await checkAccount(); try current(token)
            guard account == item.account, item.owner == CKCurrentUserDefaultName else { throw CommandFailure("icloud_changed", "请切回查找布局时的 iCloud 账号") }
            let candidate = CloudLayoutBinding(enabled: true, shared: false, zone: item.zone, owner: item.owner, record: item.record, account: account)
            let record = try await container.privateCloudDatabase.record(for: candidate.id); try current(token)
            guard record.recordType == "HomeLayout", record["schema"] as? Int == 1 else { throw CommandFailure("cloud_schema", "云端布局版本不受支持") }
            let previous = binding
            binding = candidate
            do {
                try apply(record); binding.lastSync = Date(); try persist()
                conflict = false; remoteConflict = nil; ownedLayouts = []
                failures = 0; nextAttempt = .distantPast; accountValidated = true; zoneReady = true
                status = hasLayout ? "已连接已有布局 · 已同步" : "已连接，但这份云端布局为空"
            } catch { binding = previous; throw error }
        } catch { if token == epoch { status = "连接已有布局失败：" + error.localizedDescription } }
    }

    func discoverShares() async {
        guard !busy else { return }
        busy = true; let token = epoch
        defer { if token == epoch { busy = false } }
        do {
            let account = try await container.userRecordID().recordName; try current(token)
            let db = container.sharedCloudDatabase
            let zones = try await db.allRecordZones(); try current(token)
            var found: [String: CloudLayoutInvitation] = [:]
            for zone in zones {
                var cursor: CKServerChangeToken?
                var more = true
                while more {
                    let changes = try await db.recordZoneChanges(inZoneWith: zone.zoneID, since: cursor, desiredKeys: ["title", "schema"], resultsLimit: 100)
                    try current(token)
                    for (_, result) in changes.modificationResultsByID {
                        let record = try result.get().record
                        guard record.recordType == "HomeLayout", record["schema"] as? Int == 1 else { continue }
                        let item = CloudLayoutInvitation(name: record["title"] as? String ?? "共享布局", owner: record.recordID.zoneID.ownerName, zone: record.recordID.zoneID.zoneName, record: record.recordID.recordName, account: account)
                        found[item.id] = item
                    }
                    for deletion in changes.deletions {
                        found.removeValue(forKey: deletion.recordID.zoneID.ownerName + "/" + deletion.recordID.zoneID.zoneName + "/" + deletion.recordID.recordName)
                    }
                    cursor = changes.changeToken; more = changes.moreComing
                }
            }
            invitations = found.values.sorted { $0.name < $1.name }
            UserDefaults.standard.set(try JSONEncoder().encode(invitations), forKey: "layout.cloud.invitations")
            status = invitations.isEmpty ? "没有已接受的共享布局。请先打开创建者发来的邀请。" : "找到 \(invitations.count) 个共享布局，请选择用于当前家庭"
        } catch { if token == epoch { status = "查找共享未完成：" + error.localizedDescription } }
    }
    func loadInvitations() {
        invitations = Self.savedInvitations()
    }
    static func savedInvitations() -> [CloudLayoutInvitation] {
        guard let data = UserDefaults.standard.data(forKey: "layout.cloud.invitations") else { return [] }
        return (try? JSONDecoder().decode([CloudLayoutInvitation].self, from: data)) ?? []
    }
    func useInvitation(_ item: CloudLayoutInvitation) async {
        guard !busy, !homeID.isEmpty, board?.layoutEditing == false else { return }
        busy = true; var token = epoch
        defer { if token == epoch { busy = false } }
        do {
            let account = try await container.userRecordID().recordName; try current(token)
            guard account == item.account else { throw CommandFailure("icloud_changed", "请使用接受邀请的 iCloud 账号") }
            let candidate = CloudLayoutBinding(enabled: true, shared: true, zone: item.zone, owner: item.owner, record: item.record, account: account)
            let record = try await container.sharedCloudDatabase.record(for: candidate.id); try current(token)
            try board?.activateLayoutSource(.family)
            token = epoch; busy = true
            let previous = binding
            binding = candidate
            do { try apply(record); binding.lastSync = Date(); try persist(); status = "成员只读 · 已同步" }
            catch { binding = previous; throw error }
        } catch { status = "打开共享失败：" + error.localizedDescription }
    }
    static func accept(_ metadata: CKShare.Metadata) async {
        guard metadata.containerIdentifier == containerID, let root = metadata.hierarchicalRootRecordID else { return }
        do {
            let container = CKContainer(identifier: containerID)
            let account = try await container.userRecordID().recordName
            _ = try await container.accept(metadata)
            let record = try await container.sharedCloudDatabase.record(for: root)
            var items = savedInvitations(); let item = CloudLayoutInvitation(name: record["title"] as? String ?? "共享布局", owner: root.zoneID.ownerName, zone: root.zoneID.zoneName, record: root.recordName, account: account)
            items.removeAll { $0.id == item.id }; items.append(item)
            UserDefaults.standard.set(try JSONEncoder().encode(items), forKey: "layout.cloud.invitations")
            UserDefaults.standard.removeObject(forKey: "layout.cloud.invitationError")
        } catch { UserDefaults.standard.set(error.localizedDescription, forKey: "layout.cloud.invitationError") }
        NotificationCenter.default.post(name: invitationChanged, object: nil)
    }
}
