#if !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// One uninterrupted page surface behind navigation and tab controls.
/// Contents retain safe-area insets; only the background extends beneath the bars.
struct MobileChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(.hidden, for: .navigationBar, .tabBar)
            .background(AppTheme.background.ignoresSafeArea())
    }

    @MainActor static func configure() { _ = installAppearance }

    // Configure once, before any of the mobile navigation stacks are created.
    @MainActor private static let installAppearance: Void = {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithTransparentBackground()
        navigation.backgroundColor = .clear
        navigation.shadowColor = .clear
        let navigationProxy = UINavigationBar.appearance()
        navigationProxy.standardAppearance = navigation
        navigationProxy.scrollEdgeAppearance = navigation
        navigationProxy.compactAppearance = navigation
        navigationProxy.compactScrollEdgeAppearance = navigation

        let tabs = UITabBarAppearance()
        tabs.configureWithTransparentBackground()
        tabs.backgroundColor = .clear
        tabs.shadowColor = .clear
        let tabProxy = UITabBar.appearance()
        tabProxy.standardAppearance = tabs
        tabProxy.scrollEdgeAppearance = tabs
    }()
}
#endif
