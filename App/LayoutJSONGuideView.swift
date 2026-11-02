import SwiftUI

struct LayoutImportReview: Identifiable {
    let id = UUID()
    let baseline: FloorPlanLayout
    let candidate: FloorPlanLayout
}

struct LayoutImportReviewView: View {
    @ObservedObject var board: HomeBoardModel
    let review: LayoutImportReview
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("确认导入空间布局").font(.title2.bold())
            Text("将替换房间轮廓和家具；保留底图与已有设备位置。导入后可撤销，旧布局也会备份。")
            Text("\(review.baseline.spatial?.rooms.count ?? 0) → \(review.candidate.spatial?.rooms.count ?? 0) 个区域\n\(review.baseline.spatial?.furniture.count ?? 0) → \(review.candidate.spatial?.furniture.count ?? 0) 件家具\n新增初排设备：\(review.candidate.devices.count - review.baseline.devices.count) 个").font(.headline).lineSpacing(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(review.candidate.spatial?.rooms ?? []) { room in
                        Text("\(room.name) · \(board.rooms.contains(where: { $0.id == room.id }) ? "绑定家庭房间" : "仅本地空间")")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
            if board.planImage == nil { Text("尚无底图：目前按 1000×800 的比例显示，建议先导入生成布局时使用的同一张户型图。").foregroundStyle(.orange) }
            if let error = board.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("确认导入", action: apply).buttonStyle(.borderedProminent).tint(AppTheme.selection) }
        }.padding(24).homeEditorFrame(minWidth: 540, idealWidth: 600)
    }
}

struct LayoutJSONGuideView: View {
    let context: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "rules"
    @State private var copied = ""
    private var prompt: String { SpatialImportGuide.prompt(context: context) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("AI 布局 JSON").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("将同一张户型图和提示词交给支持图片的 LLM，保存生成的 JSON 后从“JSON 布局”导入。提示词包含当前底图尺寸、房间名和设备名；只在你复制并提交给 LLM 后才会离开本机。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("复制 LLM 提示词") { UIPasteboard.general.string = prompt; copied = "已复制提示词（含当前房间与底图信息）" }.buttonStyle(.borderedProminent).tint(AppTheme.selection)
                Button("复制 JSON 示例") { UIPasteboard.general.string = SpatialImportGuide.example; copied = "已复制格式示例" }.buttonStyle(.bordered)
            }
            Picker("内容", selection: $tab) { Text("生成规则").tag("rules"); Text("LLM 提示词").tag("prompt"); Text("JSON 示例").tag("example") }.pickerStyle(.segmented)
            ScrollView {
                Text(tab == "rules" ? SpatialImportGuide.rules : tab == "prompt" ? prompt : SpatialImportGuide.example)
                    .font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            if !copied.isEmpty { Text(copied).font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(minWidth: 720, idealWidth: 850, minHeight: 600, idealHeight: 720)
    }
}
