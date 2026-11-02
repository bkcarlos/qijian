import SwiftUI

/// Shared semantic colors resolve against each window's appearance, including UIKit canvases.
enum AppTheme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in color(traits.userInterfaceStyle == .dark ? dark : light) }
    }
    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let backgroundUI = adaptive(0xF5F5F0, 0x161D1F)
    static let sidebarUI = adaptive(0xEDF0E8, 0x1B2426)
    static let surfaceUI = adaptive(0xFFFFFF, 0x253033)
    static let raisedUI = adaptive(0xF7F7F7, 0x303D40)
    static let accentUI = adaptive(0x26645C, 0x8AD6C4)
    static let selectionUI = adaptive(0x26645C, 0x285D54)
    static let canvasUI = adaptive(0xF2F7F5, 0x172225)
    static let roomUI = adaptive(0xEDE2C7, 0x444036)
    static let wetRoomUI = adaptive(0xD6E8E6, 0x334A4B)
    static let wallUI = adaptive(0x666E69, 0x9AA8A4)
    static let wall3DUI = adaptive(0xF7F7F7, 0x61716E)
    static let gridUI = adaptive(0xDDE5E1, 0x2F4246)
    static let onCardUI = adaptive(0xFFF7E0, 0x423824)
    static let background = Color(backgroundUI)
    static let sidebar = Color(sidebarUI)
    static let surface = Color(surfaceUI)
    static let raised = Color(raisedUI)
    static let accent = Color(accentUI)
    static let selection = Color(selectionUI)
    static let canvas = Color(canvasUI)
    static let onCard = Color(onCardUI)
    static func scheme(_ preference: String) -> ColorScheme? {
        preference == "dark" ? .dark : preference == "light" ? .light : nil
    }
}

struct MacAppearanceSettings: View {
    @AppStorage("appearance.mac") private var mode = "system"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("外观", systemImage: "circle.lefthalf.filled").font(.headline)
            Picker("外观模式", selection: $mode) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }.pickerStyle(.segmented)
            Text("立即应用到 Mac 窗口、控制面板和布局画布。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
