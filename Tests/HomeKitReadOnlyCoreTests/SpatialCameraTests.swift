import XCTest
@testable import HomeKitReadOnlyCore
final class SpatialCameraTests: XCTestCase {
    func testOrbitAndZoomStayUsableUnderLargeInput() {
        var camera = SpatialCamera()
        camera.orbit(dx: 100_000,dy: 100_000)
        XCTAssertTrue((-360...360).contains(camera.yaw)); XCTAssertEqual(camera.elevation,85)
        camera.orbit(dx: 0,dy: -100_000); XCTAssertEqual(camera.elevation,20)
        camera.magnify(1000); XCTAssertEqual(camera.zoom,4)
        camera.magnify(0.000001); XCTAssertEqual(camera.zoom,0.35)
        let valid = camera
        camera.orbit(dx:.nan,dy:0); camera.magnify(.infinity); camera.scroll(.nan)
        XCTAssertEqual(camera,valid)
    }
    func testPanFollowsCameraHeadingAndResetClearsOffsets() {
        var camera = SpatialCamera(); camera.yaw = 0
        camera.pan(dx: 100,dy: 0,unitsPerPoint: 0.01)
        XCTAssertEqual(camera.offsetX,-1,accuracy:0.0001); XCTAssertEqual(camera.offsetZ,0,accuracy:0.0001)
        camera = SpatialCamera(); camera.yaw = 90
        camera.pan(dx: 100,dy: 0,unitsPerPoint: 0.01)
        XCTAssertEqual(camera.offsetX,0,accuracy:0.0001); XCTAssertEqual(camera.offsetZ,1,accuracy:0.0001)
        camera = SpatialCamera(); XCTAssertEqual(camera.offsetZ,0); XCTAssertEqual(camera.zoom,1)
    }
}
