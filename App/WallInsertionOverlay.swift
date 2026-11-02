import SwiftUI

/// Only wall segments receive events; vertex handles and the rest of the tracing
/// canvas remain available to their existing gestures underneath this overlay.
struct WallInsertionOverlay: UIViewRepresentable {
    var room: SpatialRoom
    var origin: CGPoint
    var imageSize: CGSize
    var enabled: Bool
    var insert: (Int, Double) -> Void
    func makeUIView(context: Context) -> WallView {
        let view = WallView(); view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: view))
        return view
    }
    func updateUIView(_ view: WallView, context: Context) { view.configuration = self }
    final class WallView: UIView, UIContextMenuInteractionDelegate {
        var configuration: WallInsertionOverlay?
        func hit(_ point: CGPoint) -> SpatialRoom.WallHit? {
            guard let c = configuration, c.enabled else { return nil }
            let x = point.x-c.origin.x, y = point.y-c.origin.y
            guard !c.room.points.contains(where: { hypot(x-$0.x*c.imageSize.width, y-$0.y*c.imageSize.height) <= 16 }),
                  let hit = c.room.nearestWall(x: x, y: y, width: c.imageSize.width, height: c.imageSize.height), hit.distance <= 12 else { return nil }
            return hit
        }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { hit(point) != nil }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let c = configuration, let hit = hit(location) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(title: "\(c.room.name) · 墙体 \(hit.edge + 1)", children: [
                    UIAction(title: "在此添加角点", image: UIImage(systemName: "plus.circle"), attributes: c.room.points.count < 100 ? [] : .disabled) { _ in
                        guard let current = self?.configuration, current.enabled, current.room == c.room else { return }
                        c.insert(hit.edge, hit.fraction)
                    }
                ])
            }
        }
    }
}
