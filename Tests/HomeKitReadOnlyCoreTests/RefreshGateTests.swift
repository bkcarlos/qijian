import XCTest
@testable import HomeKitReadOnlyCore

final class RefreshGateTests: XCTestCase {
    func testManualAndAutomaticCannotOverlapAndBatchGapsDoNotUnlockRound() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.begin(at:0,automatic:false))
        for time in [0.0,0.1,1,15,30] {
            XCTAssertFalse(gate.begin(at:time,automatic:false))
            XCTAssertFalse(gate.begin(at:time,automatic:true))
        }
        XCTAssertTrue(gate.isRunning)
        gate.finish(at:31)
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.begin(at:32,automatic:false))
    }
    func testAutomaticCooldownStartsWhenRoundFinishes() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.begin(at:0,automatic:true))
        gate.finish(at:20)
        XCTAssertFalse(gate.begin(at:20,automatic:true))
        XCTAssertFalse(gate.begin(at:34.99,automatic:true))
        XCTAssertTrue(gate.begin(at:35,automatic:true))
    }
    func testCleanupAllowsManualRetryButDoesNotQueueMoreWork() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.begin(at:10,automatic:false))
        XCTAssertFalse(gate.begin(at:11,automatic:false))
        gate.finish(at:12) // The same cleanup runs on success, error or cancellation.
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.begin(at:12,automatic:false))
        gate.finish(at:13)
        XCTAssertFalse(gate.begin(at:20,automatic:true))
    }
}
