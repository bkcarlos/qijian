import Foundation

public enum DeviceVisualState: String {
    case on, off, pending, unreachable, unknown, sensor
    public init(isOn: Bool?, reachable: Bool, pending: Bool, hasPower: Bool) {
        if pending { self = .pending }
        else if !reachable { self = .unreachable }
        else if !hasPower { self = .sensor }
        else if let isOn { self = isOn ? .on : .off }
        else { self = .unknown }
    }
    public var label: String {
        switch self {
        case .on: return "已开启"
        case .off: return "已关闭"
        case .pending: return "处理中"
        case .unreachable: return "不可达"
        case .unknown: return "待刷新"
        case .sensor: return "传感器"
        }
    }
    public var badge: String {
        switch self { case .on: return "开"; case .off: return "关"; case .pending: return "…"; case .unreachable: return "!"; case .unknown: return "?"; case .sensor: return "" }
    }
}
