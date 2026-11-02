import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var home: HomeStore
    @ObservedObject var board: HomeBoardModel
    @State private var choosingExportFolder = false
    @State private var exportControl = false
    @State private var showingConnectionDetails = false
    private let accent = AppTheme.accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                card { MacAppearanceSettings() }
                card { CloudLayoutSettingsView(board: board) }
                card {
                    HStack(alignment: .top, spacing: 14) {
                        icon("power")
                        Toggle(isOn: $model.startsMCPOnLaunch) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("随软件启动 MCP").font(.headline)
                                detail("记住你的选择，每次打开“栖间”时自动启动服务。")
                            }
                        }.toggleStyle(.switch)
                    }
                    detail("开启后立即启动；关闭仅影响下次启动。退出软件时，服务同时结束。")
                        .padding(.leading, 48)
                }

                card {
                    HStack(spacing: 14) {
                        icon("network")
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Text("MCP 服务").font(.headline)
                                status(model.running ? "运行中" : (model.started ? "未就绪" : "未运行"), active: model.running)
                            }
                            detail("让已连接的 AI 客户端查询家庭、设备和场景。")
                        }
                        Spacer(minLength: 12)
                        if model.started {
                            Button("停止服务") { model.stop() }.buttonStyle(.bordered)
                        } else {
                            Button("启动服务") { model.start() }.buttonStyle(.borderedProminent).tint(AppTheme.selection)
                        }
                    }
                    if !model.running {
                        detail(model.serverState).padding(.leading, 48)
                    }
                }

                card {
                    HStack(alignment: .top, spacing: 14) {
                        icon("hand.raised")
                        Toggle(isOn: $model.writesEnabled) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("允许 MCP 修改和控制设备").font(.headline)
                                detail(model.writesEnabled
                                    ? "持有控制凭据的客户端可以操作设备、修改房间和场景。"
                                    : "当前仅允许查询。开启后，客户端还需使用独立控制凭据。")
                            }
                        }.toggleStyle(.switch).disabled(!model.started)
                    }
                    detail(model.started ? "每次启动默认关闭。关闭后不再接受新的控制请求。" : "先启动 MCP 服务，即可设置控制权限。")
                        .padding(.leading, 48)
                }

                card {
                    HStack(spacing: 14) {
                        icon("house")
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Text("Apple 家庭").font(.headline)
                                status(home.loaded && home.authorization == "authorized" ? "已连接" : "未连接", active: home.loaded && home.authorization == "authorized")
                            }
                            detail(home.summary)
                        }
                        Spacer(minLength: 12)
                        Button(home.loaded ? "刷新连接" : "连接家庭") { home.connect() }
                            .buttonStyle(.bordered)
                    }
                    detail("设备和房间在左侧管理，这里查看连接状态。")
                        .padding(.leading, 48)
                }

                card {
                    DisclosureGroup(isExpanded: $showingConnectionDetails) {
                        VStack(alignment: .leading, spacing: 16) {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("服务地址").font(.subheadline.weight(.semibold))
                                Text(verbatim: "http://127.0.0.1:\(HTTPServer.port)/mcp")
                                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                detail("仅供本机客户端连接，访问需要凭据。")
                            }
                            HStack(spacing: 10) {
                                Button("导出只读凭据…") { exportControl = false; choosingExportFolder = true }
                                    .disabled(model.tokenPath.isEmpty)
                                Button("导出控制凭据…") { exportControl = true; choosingExportFolder = true }
                                    .disabled(!model.writesEnabled || !model.started)
                            }.buttonStyle(.bordered)
                            if !model.tokenPath.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("本机凭据位置").font(.subheadline.weight(.semibold))
                                    Text(model.tokenPath).font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if !model.exportStatus.isEmpty {
                                Text(model.exportStatus).font(.callout).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(.top, 8)
                    } label: {
                        HStack(spacing: 14) {
                            icon("key")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("客户端连接").font(.headline).foregroundStyle(.primary)
                                detail("服务地址与访问凭据")
                            }
                        }
                    }
                }
                card {
                    HStack(spacing: 14) {
                        icon("info.circle")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("栖间").font(.headline)
                            detail("关于此应用")
                        }
                        Spacer(minLength: 12)
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 840)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $choosingExportFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): model.exportCredential(to: folder, control: exportControl)
            case .failure(let error): model.exportStatus = "未导出：\(error.localizedDescription)"
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.08)))
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .medium))
            .foregroundStyle(accent).frame(width: 34, height: 34)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func status(_ text: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(active ? accent : .gray).frame(width: 5, height: 5)
            Text(text)
        }.font(.caption.weight(.medium)).foregroundStyle(active ? accent : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((active ? accent : .gray).opacity(0.08), in: Capsule())
    }
}
