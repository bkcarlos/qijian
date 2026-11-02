import XCTest
@testable import HomeKitReadOnlyCore

final class HomeSelectionTests: XCTestCase {
    func testRestoresRememberedHomeAtStartup() {
        XCTAssertEqual(HomeSelection.resolve(available:["A","B"],current:"",remembered:"B"),"B")
    }
    func testRefreshKeepsTheActiveHome() {
        XCTAssertEqual(HomeSelection.resolve(available:["B","A"],current:"A",remembered:"B"),"A")
    }
    func testRemovedOrDifferentAccountHomeIsNeverSelected() {
        XCTAssertEqual(HomeSelection.resolve(available:["C"],current:"A",remembered:"B"),"C")
        XCTAssertNil(HomeSelection.resolve(available:[],current:"A",remembered:"B"))
    }
    func testTransientEmptyInventoryDoesNotRequireLosingPreference() {
        let remembered = "B"
        XCTAssertNil(HomeSelection.resolve(available:[],current:"",remembered:remembered))
        XCTAssertEqual(HomeSelection.resolve(available:["A","B"],current:"",remembered:remembered),"B")
    }
}
