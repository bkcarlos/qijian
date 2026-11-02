import UIKit

/// Decorative illumination follows the placed fixture, never its HomeKit room name.
/// It has no hit targets and does not change the saved layout or device state.
@MainActor
enum LightingAppearance {
    struct Source {
        let point: PlanPoint
        let room: SpatialRoom?
        let radius: Double // normalized to plan width, so light stays circular at any aspect ratio
    }
    static func sources(board: HomeBoardModel, plan: FloorPlanLayout, aspect: Double) -> [Source] {
        let rooms = plan.spatial?.rooms ?? []
        return board.devices.compactMap { device in
            guard device.isLighting, device.reachable, board.isOn(device) == true,
                  let point = plan.devices[device.id] else { return nil }
            let room = rooms.first { $0.contains(point) }
            guard rooms.isEmpty || room != nil else { return nil }
            let width = (room?.points.map(\.x).max() ?? 0.2) - (room?.points.map(\.x).min() ?? 0)
            let height = ((room?.points.map(\.y).max() ?? 0.2) - (room?.points.map(\.y).min() ?? 0)) * aspect
            return Source(point: point, room: room, radius: max(0.08, min(0.22, max(width, height) * 0.68)))
        }
    }
    private static let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        UIColor(red: 1, green: 0.97, blue: 0.80, alpha: 0.78).cgColor,
        UIColor(red: 1, green: 0.94, blue: 0.65, alpha: 0.52).cgColor,
        UIColor(red: 1, green: 0.88, blue: 0.45, alpha: 0.15).cgColor,
        UIColor(red: 1, green: 0.88, blue: 0.45, alpha: 0).cgColor
    ] as CFArray, locations: [0, 0.24, 0.65, 1])!

    static func draw(_ sources: [Source], in context: CGContext, width: CGFloat, project: (PlanPoint) -> CGPoint) {
        for source in sources {
            context.saveGState()
            if let room = source.room {
                let path = CGMutablePath()
                for (index, point) in room.points.enumerated() {
                    if index == 0 { path.move(to: project(point)) } else { path.addLine(to: project(point)) }
                }
                path.closeSubpath(); context.addPath(path); context.clip()
            }
            let center = project(source.point)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: source.radius * width, options: [])
            context.restoreGState()
        }
    }

    /// Small per-room texture keeps the 3D glow inside walls, including concave outlines.
    static func texture(_ sources: [Source], bounds: CGRect, aspect: Double) -> UIImage {
        let extent = max(bounds.width, bounds.height * aspect)
        let width = max(1, 640 * bounds.width / extent)
        let height = max(1, 640 * bounds.height * aspect / extent)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { renderer in
            draw(sources, in: renderer.cgContext, width: width / bounds.width) { point in
                CGPoint(x: (point.x - bounds.minX) / bounds.width * width,
                        y: (point.y - bounds.minY) / bounds.height * height)
            }
        }
    }
}
