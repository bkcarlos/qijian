import XCTest
@testable import HomeKitReadOnlyCore

final class FurnitureAssetTests: XCTestCase {
    func testBundledCatalogAndResources() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Furniture")
        let assets = try JSONDecoder().decode([FurnitureAsset].self,from:Data(contentsOf:root.appendingPathComponent("catalog.json")))
        XCTAssertEqual(assets.count,120); XCTAssertEqual(Set(assets.map(\.id)).count,120)
        for asset in assets {
            XCTAssertTrue(FurnitureAsset.validID(asset.id)); XCTAssertGreaterThan(asset.width,0); XCTAssertGreaterThan(asset.depth,0)
            XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(asset.file).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(asset.preview).path))
        }
        XCTAssertTrue(assets.contains { $0.matches("冰箱",category:"厨房") })
        XCTAssertTrue(assets.contains { $0.matches("FRIDGE",category:"全部") })
        XCTAssertFalse(assets.contains { $0.matches("冰箱",category:"卧室") })
        XCTAssertFalse(assets.contains { $0.matches("",category:"我的模型") })
    }
    func testModelLayoutRoundTripAndInvalidReferences() throws {
        var input = try SpatialCalibration.decode(Data(SpatialImportGuide.example.utf8))
        var furniture = SpatialFurniture(kind:"model",point:PlanPoint(x:0.5,y:0.5))
        furniture.assetID = "kenney:kitchenFridge"
        input.furniture.append(furniture)
        let decoded = try SpatialCalibration.decode(JSONEncoder().encode(input))
        XCTAssertEqual(decoded.furniture,input.furniture)
        for id in ["", "../outside", "kenney:../outside", "kenney:a/b", "https:remote"] {
            input.furniture[input.furniture.count-1].assetID = id
            XCTAssertThrowsError(try input.validate())
        }
        input.furniture[input.furniture.count-1].assetID = nil
        XCTAssertThrowsError(try input.validate())
        input.furniture[input.furniture.count-1].kind = "bed"
        XCTAssertNoThrow(try input.validate())
        input.furniture[input.furniture.count-1].assetID = "custom:abc-123"
        XCTAssertThrowsError(try input.validate())
    }
}
