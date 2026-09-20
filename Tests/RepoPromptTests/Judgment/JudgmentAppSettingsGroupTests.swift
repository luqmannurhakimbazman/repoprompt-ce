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
    private var temporaryRoot: URL?
    private var suiteName: String?

    override func tearDown() {
        JudgmentAPIKeyStore.storageForTesting = nil
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        if let suiteName { UserDefaults().removePersistentDomain(forName: suiteName) }
        temporaryRoot = nil
        suiteName = nil
        super.tearDown()
    }

    private func service() throws -> AppSettingsMCPService {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JudgmentAppSettingsGroupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoot = root

        let suite = "JudgmentAppSettingsGroupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        suiteName = suite

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        return AppSettingsMCPService(store: store)
    }

    func testJudgmentGroupListsEveryDebugJudgmentSetting() async throws {
        let listed = try await service().handleForTesting([
            "op": .string("list"),
            "group": .string("judgment"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let keys = Set(settings.compactMap { $0.objectValue?["key"]?.stringValue })
        XCTAssertEqual(keys, ["judgment.shadow_enabled", "judgment.shadow_log_file_path", "judgment.api_key"])
    }

    // MARK: - The key is write-only

    /// The whole point of `judgment.api_key` is that it has a write path and no read path.
    /// A read that returned the key would put a live third-party credential into
    /// `app_settings list` output, which agents and diagnostics dumps both read.
    func testReadingTheAPIKeySettingReturnsPresenceRatherThanTheKey() async throws {
        let storage = InMemorySecureStore()
        JudgmentAPIKeyStore.storageForTesting = storage
        let service = try service()
        let secret = "sk-systemone-do-not-print-\(UUID().uuidString)"

        _ = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("judgment.api_key"),
            "value": .string(secret)
        ])
        XCTAssertEqual(try storage.getPlainValue(for: .typeSafeSystemOneAPI), secret, "The write must actually store the key.")

        let got = try await service.handleForTesting([
            "op": .string("get"),
            "key": .string("judgment.api_key")
        ])
        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("judgment"),
            "detailed": .bool(true)
        ])

        for rendered in [String(describing: got), String(describing: listed)] {
            XCTAssertFalse(rendered.contains(secret), "The stored key must not appear anywhere in the response.")
            XCTAssertTrue(rendered.contains(JudgmentAPIKeyStore.presentLabel))
        }
    }

    func testAnEmptyValueDeletesTheStoredKey() async throws {
        let storage = InMemorySecureStore()
        JudgmentAPIKeyStore.storageForTesting = storage
        let service = try service()

        _ = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("judgment.api_key"),
            "value": .string("sk-systemone-abc")
        ])
        XCTAssertEqual(JudgmentAPIKeyStore.presenceLabel(), JudgmentAPIKeyStore.presentLabel)

        _ = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("judgment.api_key"),
            "value": .string("   ")
        ])

        XCTAssertNil(try storage.getPlainValue(for: .typeSafeSystemOneAPI))
        XCTAssertEqual(JudgmentAPIKeyStore.presenceLabel(), JudgmentAPIKeyStore.absentLabel)
    }

    func testAStoredKeyIsTrimmedSoAPastedNewlineDoesNotBreakAuthorization() throws {
        let storage = InMemorySecureStore()
        JudgmentAPIKeyStore.storageForTesting = storage

        try JudgmentAPIKeyStore.write("  sk-systemone-abc\n")

        XCTAssertEqual(try storage.getPlainValue(for: .typeSafeSystemOneAPI), "sk-systemone-abc")
    }

    // MARK: - Doubles

    /// Keeps the suite away from a real Keychain, which a signed debug test run would
    /// otherwise reach.
    final class InMemorySecureStore: SecurePlainStringStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[account.identifier]
        }

        func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
            lock.lock()
            defer { lock.unlock() }
            values[account.identifier] = value
        }

        func deletePlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
            lock.lock()
            defer { lock.unlock() }
            values[account.identifier] = nil
        }
    }
}
