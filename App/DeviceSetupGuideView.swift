import SwiftUI

struct DeviceSetupGuideSession: Identifiable {
    let id = UUID()
    let homeID: String
    let homeName: String
    let existingIDs: Set<String>
}

struct DeviceSetupGuideView: View {
    @ObservedObject var board: HomeBoardModel
    @ObservedObject var homeStore: HomeStore
    let session: DeviceSetupGuideSession
    @Environment(\.dismiss) private var dismiss
    @State private var showingHelp = false
    @State private var checked = false
    private let accent = AppTheme.accent
    private var currentHome: BoardHome? { board.homes.first { $0.id == session.homeID } }
    private var newDevices: [BoardDevice] {
        currentHome?.accessories.filter { !session.existingIDs.contains($0.id) } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("添加设备").font(.title2.bold())
                    Text("在手机配对，在 Mac 管理").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭添加设备引导")
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("添加到：\(currentHome?.name ?? session.homeName)", systemImage: "house")
                        .font(.headline).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    step(1, "打开 iPhone 或 iPad 的“家庭”", "选择上方同一个家庭，确保手机与这台 Mac 都有该家庭的访问权限。")
                    step(2, "点“＋” → “添加配件”", "给设备通电，用手机扫描设备或说明书上的 HomeKit / Matter 配对码，按系统提示完成配对。")
                    step(3, "命名设备并选择房间", "完成后，新设备会通过 Apple 家庭同步到这里，也会显示在对应房间。同步时间取决于 Apple 家庭与网络状态。")
                    syncStatus
                    DisclosureGroup("还没有看到设备？", isExpanded: $showingHelp) {
                        Text("确认手机中配对已完成，且设备添加到了同一个家庭；检查两端网络及家庭访问权限。可以稍候再点“检查同步”，或切回本应用。通过 HA 桥接的设备，需要先在 HA 中接入并配置桥接。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                Text("关闭引导后仍会自动同步").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("检查同步") { homeStore.refreshPreview(); checked = true }
                    .buttonStyle(.bordered)
                Button(newDevices.isEmpty ? "完成" : "查看设备") { dismiss() }
                    .buttonStyle(.borderedProminent).tint(AppTheme.selection)
            }.padding(20)
        }.frame(width: 580, height: 650).tint(accent)
    }

    private var syncStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            if homeStore.authorization != "authorized" || currentHome == nil {
                Label("暂时无法读取此家庭", systemImage: "exclamationmark.circle").font(.headline)
                Text("请检查 Mac 的家庭访问权限和家庭连接。").font(.callout)
            } else if newDevices.isEmpty {
                Label("等待手机完成配对", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                Text(checked ? "已检查，暂未发现新设备；同步监听会继续。" : "已开启同步监听，收到新设备后会在这里显示。")
                    .font(.callout)
            } else {
                Label("已同步 \(newDevices.count) 个新设备", systemImage: "checkmark.circle.fill").font(.headline)
                ForEach(newDevices) { device in
                    HStack {
                        Text(device.name)
                        Spacer()
                        Text(device.roomName).foregroundStyle(.secondary)
                    }.font(.callout)
                }
                Text("设备已加入列表；需要在户型图上显示时，可进入“布置空间”放置。")
                    .font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .foregroundStyle(accent).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.callout.bold()).foregroundStyle(accent)
                .frame(width: 28, height: 28).background(accent.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
