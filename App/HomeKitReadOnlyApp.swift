import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    let home = HomeStore()
    let commands = ControlRouter()
    @Published var writesEnabled = false { didSet { commands.writesEnabled = writesEnabled } }
    @Published var serverState = "尚未启动"
    @Published var tokenPath = ""
    @Published var exportStatus = ""
    @Published var running = false
    @Published var started = false
    @Published var startsMCPOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(startsMCPOnLaunch, forKey: "mcp.startsOnLaunch")
            if startsMCPOnLaunch { start() }
        }
    }
    private var server: HTTPServer?

    init() {
        startsMCPOnLaunch = UserDefaults.standard.bool(forKey: "mcp.startsOnLaunch")
        // AppModel is shared by all windows. Launch once, not on every view appearance.
        #if targetEnvironment(macCatalyst)
        if startsMCPOnLaunch { start() }
        #endif
    }

    func start() {
        guard server == nil else { return }
        do {
            let credential = try LocalCredential.loadOrCreate()
            tokenPath = credential.path
            let control = try LocalCredential.loadOrCreate(control: true)
            let newServer = HTTPServer(token: credential.token, controlToken: control.token, handle: { [home, commands] data, role in
                await commands.handle(data, role: role, inventory: { home.snapshot() }, perform: { name, args in
                    try await home.perform(name, arguments: args)
                })
            }, onState: { [weak self] state in
                self?.serverState = state
                self?.running = state.hasPrefix("运行中")
            })
            try newServer.start()
            server = newServer
            started = true
            serverState = "正在启动…"
            home.connect()
        } catch { serverState = error.localizedDescription }
    }

    func stop() { writesEnabled = false; server?.stop(); server = nil; started = false; running = false; serverState = "已停止" }

    func exportCredential(to folder: URL, control: Bool) {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            guard !control || writesEnabled else { throw CommandFailure("writes_disabled", "请先在本机打开修改和控制权限") }
            let credential = try LocalCredential.loadOrCreate(control: control)
            let directory = folder.appendingPathComponent(".homekit-mcp", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let destination = directory.appendingPathComponent(control ? "control.token" : "access.token")
            try Data(credential.token.utf8).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            exportStatus = "客户端凭据已保存：\(destination.path)"
        } catch { exportStatus = "导出失败：\(error.localizedDescription)" }
    }
}

@main
struct HomeKitReadOnlyApp: App {
    @UIApplicationDelegateAdaptor(LayoutAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage("appearance.mac") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(macCatalyst)
            HomeBoardView(app: model)
                .preferredColorScheme(AppTheme.scheme(appearance))
                .frame(minWidth: 1000, minHeight: 680)
                .background(WindowTitlebarConfiguration())
            #else
            MobileHomeView(app: model)
            #endif
        }
    }
}

/// Let the page header share the native titlebar area instead of leaving a blank strip.
private struct WindowTitlebarConfiguration: UIViewRepresentable {
    final class WindowView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if targetEnvironment(macCatalyst)
            window?.windowScene?.titlebar?.titleVisibility = .hidden
            window?.windowScene?.titlebar?.toolbar = nil
            #endif
        }
    }
    func makeUIView(context: Context) -> WindowView { WindowView() }
    func updateUIView(_ view: WindowView, context: Context) {}
}
