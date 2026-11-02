import SwiftUI

struct DeviceAppearance {
    let state: DeviceVisualState
    var fill: UIColor {
        switch state {
        case .on: return UIColor(red: 1, green: 0.77, blue: 0.26, alpha: 1)
        case .pending: return UIColor(red: 1, green: 0.90, blue: 0.68, alpha: 1)
        case .off, .sensor: return AppTheme.surfaceUI
        case .unreachable, .unknown: return AppTheme.adaptive(0xDBDBDB, 0x354246)
        }
    }
    var ink: UIColor {
        switch state {
        case .on, .pending: return UIColor(red: 0.38, green: 0.22, blue: 0.02, alpha: 1)
        case .off, .sensor: return AppTheme.adaptive(0x47595C, 0xD4E6E1)
        case .unreachable, .unknown: return AppTheme.adaptive(0x666666, 0xBBC7C8)
        }
    }
    var border: UIColor { state == .on ? UIColor(red: 0.76, green: 0.46, blue: 0.02, alpha: 1) : ink.withAlphaComponent(0.4) }
    func image(symbol: String) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            if state == .on {
                fill.withAlphaComponent(0.28).setFill(); UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 98, height: 98)).fill()
                context.cgContext.setShadow(offset: .zero, blur: 6, color: fill.withAlphaComponent(0.65).cgColor)
            }
            let circle = UIBezierPath(ovalIn: CGRect(x: 10, y: 10, width: 76, height: 76))
            fill.setFill(); circle.fill(); context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            border.setStroke(); circle.lineWidth = 3; if state == .unknown { circle.setLineDash([5, 4], count: 2, phase: 0) }; circle.stroke()
            UIImage(systemName: state == .pending ? "hourglass" : symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 42, weight: .semibold))?
                .withTintColor(ink, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 27, y: 25, width: 42, height: 42))
            if !state.badge.isEmpty {
                let badge = UIBezierPath(ovalIn: CGRect(x: 65, y: 63, width: 33, height: 33))
                UIColor(red: 0.25, green: 0.32, blue: 0.33, alpha: 1).setFill(); badge.fill(); UIColor.white.setStroke(); badge.lineWidth = 2; badge.stroke()
                let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
                (state.badge as NSString).draw(in: CGRect(x: 65, y: 66, width: 33, height: 29), withAttributes: [.font: UIFont.systemFont(ofSize: 23, weight: .bold), .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
            }
        }
    }
}

struct DeviceStatusBadge: View {
    let state: DeviceVisualState
    var body: some View {
        let style = DeviceAppearance(state: state)
        Text(state.label).font(.caption.bold()).foregroundStyle(Color(style.ink))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color(style.fill), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(style.border), lineWidth: 1))
    }
}
