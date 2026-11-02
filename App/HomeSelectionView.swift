import SwiftUI

struct HomeSelectionView: View {
    @ObservedObject var board: HomeBoardModel
    let onSelect: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("使用系统 Apple 账号", systemImage:"person.crop.circle.badge.checkmark").font(.headline)
                    Text("这里显示你在 Apple 家庭中可访问的家庭，包括自己创建的和已接受邀请的家庭。无需在本 App 重复登录。").font(.callout).foregroundStyle(.secondary)
                }
                Section("可选择的家庭 · \(board.homes.count)") {
                    if board.homes.isEmpty {
                        Text("暂未发现家庭").font(.headline)
                        Text("请先在系统设置登录 iCloud，并允许本 App 访问家庭。").foregroundStyle(.secondary)
                    }
                    ForEach(board.homes) { home in
                        Button {
                            board.selectHome(home.id)
                            if board.homeID == home.id { onSelect(); dismiss() }
                        } label: {
                            HStack(spacing:14) {
                                Image(systemName:"house.fill").font(.title2).foregroundStyle(AppTheme.accent)
                                VStack(alignment:.leading,spacing:5) {
                                    Text(home.name).font(.headline).foregroundStyle(.primary)
                                    Text("\(home.rooms.filter { !$0.isDefault }.count) 个房间 · \(home.accessories.count) 个设备 · \(home.scenes.count) 个场景")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if home.id == board.homeID { Image(systemName:"checkmark.circle.fill").foregroundStyle(AppTheme.accent).accessibilityLabel("当前家庭") }
                            }.padding(.vertical,8).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!board.canSwitchHome)
                    }
                }
                Section("没有找到另一处家庭？") {
                    Text("先在 Apple「家庭」中创建家庭或接受邀请，再回到这里刷新。家庭共享决定可访问哪些设备；户型布局需在各家庭的 iCloud 布局设置中单独连接或接受共享。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("刷新家庭列表") { board.app.home.connect() }
                }
                Section {
                    Text("会在本机记住上次选择。切换家庭时，设备、场景和户型一并切换。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !board.canSwitchHome { Text("请先完成当前控制操作或退出布局编辑，再切换家庭。").font(.caption).foregroundStyle(.secondary) }
                }
            }.navigationTitle("选择家庭").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(AppTheme.accent)
        #if targetEnvironment(macCatalyst)
        .frame(minWidth:480,idealWidth:540,minHeight:520,idealHeight:620)
        #endif
    }
}
