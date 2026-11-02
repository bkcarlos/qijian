import XCTest
@testable import HomeKitReadOnlyCore

final class DeviceVisualStateTests: XCTestCase {
    func testUnknownAndUnreachableNeverLookLikeConfirmedPower() {
        XCTAssertEqual(DeviceVisualState(isOn: true, reachable: false, pending: false, hasPower: true), .unreachable)
        XCTAssertEqual(DeviceVisualState(isOn: nil, reachable: true, pending: false, hasPower: true), .unknown)
        XCTAssertNotEqual(DeviceVisualState.unknown.badge, DeviceVisualState.off.badge)
        XCTAssertEqual(DeviceVisualState(isOn: false, reachable: true, pending: false, hasPower: true).label, "已关闭")
        XCTAssertEqual(DeviceVisualState(isOn: true, reachable: true, pending: false, hasPower: true).badge, "开")
    }
    func testInFlightAndPassiveSensorsHaveDistinctVisualStates() {
        XCTAssertEqual(DeviceVisualState(isOn: true, reachable: true, pending: true, hasPower: true), .pending)
        XCTAssertEqual(DeviceVisualState(isOn: false, reachable: true, pending: true, hasPower: true), .pending)
        XCTAssertEqual(DeviceVisualState(isOn: nil, reachable: true, pending: false, hasPower: false), .sensor)
        XCTAssertTrue(DeviceVisualState.sensor.badge.isEmpty)
    }
}
