import SwiftUI

struct LayoutSourceMenu: View {
    @ObservedObject var board: HomeBoardModel
    @State private var showingSettings = false
    var body: some View {
        Menu {
            ForEach(LayoutSource.allCases, id: \.self) { source in
                Button {
                    board.switchLayoutSource(source)
                    if board.layoutSource == .family && board.cloud.binding.record.isEmpty { showingSettings = true }
                } label: {
                    Label(source.title, systemImage: board.layoutSource == source ? "checkmark.circle.fill" : (source == .personal ? "person" : "person.2"))
                }.disabled(!board.canSwitchLayout)
            }
            Divider()
            Button("管理布局与同步") { showingSettings = true }
        } label: {
            HStack(spacing: 5) {
                Text(board.layoutSource.title).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2)
            }.frame(minHeight: 36)
        }.accessibilityLabel("布局来源，当前：" + board.layoutSource.title)
            .sheet(isPresented: $showingSettings) { LayoutSourceSettingsSheet(board: board) }
    }
}

struct LayoutSourceSettingsSheet: View {
    @ObservedObject var board: HomeBoardModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { CloudLayoutSettingsView(board: board).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
                .navigationTitle("布局与同步")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 520, idealHeight: 650)
        #endif
    }
}
