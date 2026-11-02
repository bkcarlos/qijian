import Foundation

/// Transient viewport state; changing this never mutates HomeKit or saved layout.
public struct SpatialCamera: Equatable {
    public var yaw = 20.0
    public var elevation = 53.0
    public var zoom = 1.0
    public var offsetX = 0.0
    public var offsetZ = 0.0
    public init() {}
    public mutating func orbit(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        yaw = (yaw - dx * 0.35).truncatingRemainder(dividingBy: 360)
        elevation = min(85, max(20, elevation + dy * 0.25))
    }
    public mutating func magnify(_ factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        zoom = min(4, max(0.35, zoom * factor))
    }
    public mutating func scroll(_ dy: Double) {
        guard dy.isFinite else { return }
        magnify(exp(min(1, max(-1, dy * 0.0025))))
    }
    public mutating func pan(dx: Double, dy: Double, unitsPerPoint: Double) {
        guard dx.isFinite, dy.isFinite, unitsPerPoint.isFinite, unitsPerPoint > 0 else { return }
        let radians = yaw * .pi / 180
        let vertical = dy * unitsPerPoint / max(0.3, sin(elevation * .pi / 180))
        offsetX += -dx * unitsPerPoint * cos(radians) + vertical * sin(radians)
        offsetZ += dx * unitsPerPoint * sin(radians) + vertical * cos(radians)
        offsetX = min(20, max(-20, offsetX)); offsetZ = min(20, max(-20, offsetZ))
    }
}
