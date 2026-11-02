import XCTest
@testable import HomeKitReadOnlyCore

final class LayoutSourceTests: XCTestCase {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    func testNewUserCanStartPersonalWithoutCloudOrInvitation() throws {
        try withRoot { root in
            XCTAssertEqual(try LayoutSourceStore.prepare(in: root), .personal)
            let folder = try LayoutSourceStore.directory(.personal, in: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cloud-state.json").path))
        }
    }
    func testSharedMigrationRetainsReadOnlyBindingAndOriginal() throws {
        try withRoot { root in
            let state = Data(#"{"shared":true,"record":"owner-record"}"#.utf8)
            let bundle = Data("existing-family-layout".utf8)
            try state.write(to: root.appendingPathComponent("cloud-state.json"))
            try bundle.write(to: root.appendingPathComponent("layout-bundle.json"))
            XCTAssertEqual(try LayoutSourceStore.prepare(in: root), .family)
            let family = try LayoutSourceStore.directory(.family, in: root)
            XCTAssertEqual(try Data(contentsOf: family.appendingPathComponent("cloud-state.json")), state)
            XCTAssertEqual(try Data(contentsOf: family.appendingPathComponent("layout-bundle.json")), bundle)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("layout-bundle.json")), bundle)
            let personal = try LayoutSourceStore.directory(.personal, in: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: personal.appendingPathComponent("layout-bundle.json").path))
        }
    }
    func testSwitchAndRestartPreserveBothSourcesAndCloudBindings() throws {
        try withRoot { root in
            _ = try LayoutSourceStore.prepare(in: root)
            for source in LayoutSource.allCases {
                let folder = try LayoutSourceStore.directory(source, in: root)
                try Data(source.rawValue.utf8).write(to: folder.appendingPathComponent("layout-bundle.json"))
                try Data((source.rawValue + "-binding").utf8).write(to: folder.appendingPathComponent("cloud-state.json"))
            }
            for source in [LayoutSource.family, .personal, .family] {
                try LayoutSourceStore.select(source, in: root)
                XCTAssertEqual(try LayoutSourceStore.prepare(in: root), source)
                for check in LayoutSource.allCases {
                    let folder = try LayoutSourceStore.directory(check, in: root)
                    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("layout-bundle.json")), check.rawValue)
                    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("cloud-state.json")), check.rawValue + "-binding")
                }
            }
        }
    }
    func testPersonalMigrationDoesNotOverwriteNewEditsOnNextLaunch() throws {
        try withRoot { root in
            try Data(#"{"shared":false}"#.utf8).write(to: root.appendingPathComponent("cloud-state.json"))
            try Data("legacy".utf8).write(to: root.appendingPathComponent("layout.json"))
            XCTAssertEqual(try LayoutSourceStore.prepare(in: root), .personal)
            let file = try LayoutSourceStore.directory(.personal, in: root).appendingPathComponent("layout.json")
            try Data("new-edit".utf8).write(to: file)
            _ = try LayoutSourceStore.prepare(in: root)
            XCTAssertEqual(try String(contentsOf: file), "new-edit")
        }
    }
    func testInvalidLegacyPermissionsFailInsteadOfUnlockingSharedLayout() throws {
        try withRoot { root in
            try Data(#"{"shared":"unknown"}"#.utf8).write(to: root.appendingPathComponent("cloud-state.json"))
            XCTAssertThrowsError(try LayoutSourceStore.prepare(in: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("layout-source.json").path))
        }
    }
}
