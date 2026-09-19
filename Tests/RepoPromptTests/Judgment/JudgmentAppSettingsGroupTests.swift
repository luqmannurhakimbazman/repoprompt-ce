import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// Confirms `AppSettingsMCPRegistry.groups` actually resolves `"judgment"`. Both
/// DEBUG-only shadow settings declare `group: "judgment"`, but the group name itself is a
/// separate, hand-maintained allowlist (`AppSettingsMCPService.swift:607`) that
/// `definitions(inGroup:)` validates against before filtering. Nothing else exercised that
/// allowlist, which is how the two lists drifted out of sync in the first place.
@MainActor
final class JudgmentAppSettingsGroupTests: XCTestCase {
    func testJudgmentGroupListsBothShadowSettings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JudgmentAppSettingsGroupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "JudgmentAppSettingsGroupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("judgment"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let keys = Set(settings.compactMap { $0.objectValue?["key"]?.stringValue })
        XCTAssertEqual(keys, ["judgment.shadow_enabled", "judgment.shadow_log_file_path"])
    }
}
