import SwiftUI
import UniformTypeIdentifiers

struct FurnitureCatalogView: View {
    @ObservedObject private var library = FurnitureLibrary.shared
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var category = "全部"
    @State private var importing = false
    var addBasic: (String) -> Void
    var addModel: (FurnitureAsset) -> Void
    private let columns = [GridItem(.flexible()),GridItem(.flexible())]
    private var filtered: [FurnitureAsset] { library.assets.filter { (category == "已隐藏" ? library.hidden.contains($0.id) : !library.hidden.contains($0.id)) && $0.matches(search,category:category == "已隐藏" ? "全部" : category) } }
    private var basics: [String] {
        guard category == "全部" || category == "基础组件" else { return [] }
        return SpatialFurniture.kinds.filter { search.isEmpty || SpatialFurniture.title($0).localizedStandardContains(search) || $0.localizedStandardContains(search) }
    }
    var body: some View {
        VStack(spacing:10) {
            HStack(spacing:8) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索家具",text:$search)
                    .textFieldStyle(.plain).font(.body).focused($searchFocused)
                    .accessibilityLabel("搜索家具").frame(maxWidth:.infinity)
                if !search.isEmpty {
                    Button { search = ""; searchFocused = true } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清空家具搜索")
                }
            }
            .padding(.horizontal,12).frame(height:42)
            .background(AppTheme.surface,in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(searchFocused ? Color.accentColor.opacity(0.65) : Color.gray.opacity(0.2),lineWidth:searchFocused ? 1.5 : 1))
            HStack {
                Picker("分类",selection:$category) {
                    ForEach(["全部","客厅餐厅","卧室","厨房","卫浴洗衣","书房","灯具","装饰","建筑","基础组件","我的模型","已隐藏"],id:\.self) { Text($0).tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize(horizontal:true,vertical:false).accessibilityLabel("家具分类")
                Spacer(); Text("\(filtered.count+basics.count) 件").font(.caption).foregroundStyle(.secondary)
            }
            Button { importing = true } label: { Label("导入模型",systemImage:"square.and.arrow.down").frame(maxWidth:.infinity) }.buttonStyle(.bordered).disabled(library.importing)
            if library.importing { ProgressView("正在导入并生成预览…").font(.caption) }
            ScrollView {
                if filtered.isEmpty && basics.isEmpty {
                    Text(category == "我的模型" ? "导入 USDZ，或同时选择 OBJ、MTL 和贴图。" : "没有匹配的家具，试试其他名称或分类。").font(.callout).foregroundStyle(.secondary).padding(.vertical,24)
                }
                LazyVGrid(columns:columns,spacing:10) {
                    ForEach(filtered) { asset in
                        FurnitureDragTile(title:asset.title,image:library.image(asset,thumbnail:true),payload:"home-model:\(asset.id)") { addModel(asset) }.frame(height:112).help("\(asset.title) · 点击添加或拖入画布")
                            .contextMenu {
                                if asset.isCustom { Button(library.hidden.contains(asset.id) ? "恢复到素材库" : "隐藏模型（保留布局）") { library.setHidden(asset,!library.hidden.contains(asset.id)) } }
                            }
                    }
                    ForEach(basics,id:\.self) { kind in
                        FurnitureDragTile(title:SpatialFurniture.title(kind),image:UIImage(systemName:SpatialFurniture.icon(kind)),payload:"home-furniture:\(kind)") { addBasic(kind) }.frame(height:112)
                    }
                }
            }
            Text("Kenney · CC0 · 120 个模型\n点击添加 · 拖入指定位置").font(.caption2).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[UTType(filenameExtension:"usdz")!,UTType(filenameExtension:"obj") ?? .data,UTType(filenameExtension:"mtl") ?? .data,.png,.jpeg],allowsMultipleSelection:true) { result in
            switch result {
            case .success(let urls): Task { await library.importModels(urls); if library.assets.contains(where: \.isCustom) { category = "我的模型"; search = "" } }
            case .failure(let error): library.message = error.localizedDescription
            }
        }
        .alert("模型素材库",isPresented:Binding(get:{ library.message != nil },set:{ if !$0 { library.message = nil } })) { Button("好") { library.message = nil } } message: { Text(library.message ?? "") }
    }
}
