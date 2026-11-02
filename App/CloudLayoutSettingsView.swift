import SwiftUI
import CloudKit

struct CloudLayoutSettingsView: View {
    @ObservedObject var board: HomeBoardModel
    @ObservedObject var cloud: LayoutCloudSync
    @State private var invitation: CloudLayoutInvitation?
    @State private var ownedLayout: CloudLayoutInvitation?
    init(board: HomeBoardModel) { self.board = board; cloud = board.cloud }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("布局与 iCloud", systemImage: "icloud").font(.headline)
            Picker("布局来源", selection: Binding(get: { board.layoutSource }, set: { board.switchLayoutSource($0) })) {
                Text("自己的布局").tag(LayoutSource.personal)
                Text("家庭布局").tag(LayoutSource.family)
            }.pickerStyle(.segmented).disabled(!board.canSwitchLayout)
            Text(cloud.isShared ? "家庭布局 · 只能查看" : "自己的布局 · 可以编辑，无需邀请").font(.subheadline)
            Text("两份布局分别保存，切换不会覆盖另一份。家庭布局首次授权后可直接使用。").font(.caption).foregroundStyle(.secondary)
            Text(cloud.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !cloud.diagnostics.isEmpty {
                DisclosureGroup("同步错误详情") { Text(cloud.diagnostics).font(.caption).textSelection(.enabled) }
            }
            if cloud.busy { ProgressView() }
            if let date = cloud.binding.lastSync { Text("最近同步：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            if cloud.conflict {
                Text("选择前会备份本地和云端版本。不会自动合并两次布局修改。").font(.caption)
                Button("使用 iCloud 布局") { Task { await cloud.resolve(useLocal: false) } }
                Button("保留本机布局并上传") { Task { await cloud.resolve(useLocal: true) } }
            } else if cloud.binding.enabled {
                Button("立即同步") { Task { await cloud.sync(manual: true) } }
                if !cloud.isShared {
                    Button("共享给家庭成员…") { Task { await cloud.prepareShare() } }
                    Button("管理共享成员…") { Task { await cloud.prepareShare(management: true) } }
                }
                Button("暂停此设备同步") { cloud.pause() }.foregroundStyle(.secondary)
            } else if !cloud.binding.record.isEmpty {
                Button(cloud.isShared ? "继续同步共享布局" : "启用 iCloud 布局同步") { Task { await cloud.enable() } }
            }
            Text(cloud.isShared ? "打开 App 时更新家庭布局。你可以随时切回自己的布局自由编辑；设备控制沿用 Apple 家庭权限。" : "自己的布局可在本机直接创建，也可启用 iCloud 同步到你的其他设备，或共享给家庭成员查看。").font(.caption).foregroundStyle(.secondary)
            if !cloud.isShared {
                Button("连接其他设备已有布局") { Task { await cloud.discoverOwnedLayouts() } }
                if !cloud.ownedLayouts.isEmpty {
                    Text("同一 iCloud 账号的布局").font(.subheadline.bold())
                    ForEach(cloud.ownedLayouts) { item in
                        Button { ownedLayout = item } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("连接“\(item.name)”")
                                Text("布局 \(item.record.suffix(8))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if cloud.isShared {
            Button("刷新可用的家庭布局") { Task { await cloud.discoverShares() } }
            if !cloud.invitations.isEmpty {
                Divider(); Text("可用的家庭布局").font(.subheadline.bold())
                ForEach(cloud.invitations) { item in
                    Button(cloud.binding.record == item.record && cloud.binding.owner == item.owner ? "正在使用“\(item.name)”" : "使用“\(item.name)”的家庭布局") { invitation = item }
                        .disabled(cloud.binding.record == item.record && cloud.binding.owner == item.owner)
                }
            }
            }
            if let error = UserDefaults.standard.string(forKey: "layout.cloud.invitationError") {
                Text("接受邀请未完成：\(error)\n请重新打开邀请链接重试。").font(.caption).foregroundStyle(.orange)
            }
        }.buttonStyle(.bordered).disabled(cloud.busy || board.home == nil || board.layoutEditing)
            .task(id: "\(board.homeID)|\(board.layoutSource.rawValue)") {
                if cloud.isShared && cloud.binding.record.isEmpty { await cloud.discoverShares() }
            }
            .sheet(item: $cloud.shareSheet) { item in
                if item.management { CloudSharingSheet(item: item, onChange: { Task { await cloud.sync(manual: true) } }) }
                else { CloudInvitationSheet(item: item, onChange: { Task { await cloud.sync(manual: true) } }) }
            }
            .confirmationDialog("连接“\(ownedLayout?.name ?? "已有布局")”到当前家庭？", isPresented: Binding(get: { ownedLayout != nil }, set: { if !$0 { ownedLayout = nil } }), titleVisibility: .visible) {
                Button("连接并下载布局") { if let item = ownedLayout { ownedLayout = nil; Task { await cloud.useOwnedLayout(item) } } }
            } message: { Text("本机布局会先备份，再下载所选布局。之后两台设备同步同一份布局；设备按房间与名称匹配。") }
            .confirmationDialog("将共享布局用于“\(board.home?.name ?? "当前家庭")”？", isPresented: Binding(get: { invitation != nil }, set: { if !$0 { invitation = nil } }), titleVisibility: .visible) {
                Button("使用共享布局（只读）") { if let item = invitation { invitation = nil; Task { await cloud.useInvitation(item) } } }
            } message: { Text("自己的布局会独立保留。家庭布局仅供查看，设备按房间与名称匹配。") }
    }
}

struct CloudSharingSheet: UIViewControllerRepresentable {
    let item: CloudLayoutShare
    let onChange: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: item.share, container: item.container)
        controller.availablePermissions = [.allowPrivate, .allowReadOnly]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onChange: () -> Void
        init(onChange: @escaping () -> Void) { self.onChange = onChange }
        func itemTitle(for csc: UICloudSharingController) -> String? { "家庭户型布局" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            UserDefaults.standard.set(error.localizedDescription, forKey: "layout.cloud.invitationError")
            NotificationCenter.default.post(name: LayoutCloudSync.invitationChanged, object: nil)
        }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { onChange() }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { onChange() }
    }
}

final class LayoutAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = LayoutSceneDelegate.self
        return config
    }
}
final class LayoutSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { Task { await LayoutCloudSync.accept(metadata) } }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { await LayoutCloudSync.accept(metadata) }
    }
}

/// Sync only while this window is active. Editing defers downloads until the editor closes.
struct CloudLayoutLifecycle: ViewModifier {
    @ObservedObject var board: HomeBoardModel
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.task(id: "\(board.homeID)|\(board.layoutSource.rawValue)|\(phase == .active)|\(board.layoutEditing)") {
            guard phase == .active, !board.homeID.isEmpty, !board.layoutEditing else { return }
            while !Task.isCancelled {
                await board.cloud.sync()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            }
        }
    }
}

/// Use the modern collaboration share sheet for new invitations; the older controller manages existing participants.
struct CloudInvitationSheet: UIViewControllerRepresentable {
    let item: CloudLayoutShare
    let onChange: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(item: item, onChange: onChange) }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let provider = NSItemProvider()
        provider.suggestedName = "家庭户型布局"
        provider.registerCKShare(item.share, container: item.container,
            allowedSharingOptions: CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readOnly, allowedParticipantAccessOptions: .specifiedRecipientsOnly))
        let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
        configuration.metadataProvider = { key in key == .title ? "家庭户型布局" : nil }
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        controller.completionWithItemsHandler = { _, _, _, error in
            if let error { UserDefaults.standard.set(error.localizedDescription, forKey: "layout.cloud.invitationError") }
            onChange()
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    final class Coordinator {
        let observer: CKSystemSharingUIObserver
        init(item: CloudLayoutShare, onChange: @escaping () -> Void) {
            observer = CKSystemSharingUIObserver(container: item.container)
            observer.systemSharingUIDidSaveShareBlock = { _, result in
                Task { @MainActor in
                    if case .failure(let error) = result { UserDefaults.standard.set(error.localizedDescription, forKey: "layout.cloud.invitationError") }
                    onChange()
                }
            }
        }
    }
}
