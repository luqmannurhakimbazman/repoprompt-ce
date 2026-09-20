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

    /// The advertised tool schema carried its own hand-written copy of the group list, and
    /// it had already drifted: the registry gained `judgment` in DEBUG and the schema did
    /// not. Nothing in this app validates a call against the advertised enum, so the CLI
    /// kept working and the drift stayed invisible — but a schema-validating client would
    /// refuse `list group=judgment`, and an agent reading the tool description would never
    /// learn the group exists.
    ///
    /// This asserts the property rather than the list: every group that actually holds a
    /// setting must be advertised, whatever the build configuration.
    func testTheAdvertisedSchemaNamesEveryGroupThatHoldsASetting() async throws {
        let service = try service()
        let listed = try await service.handleForTesting(["op": .string("list"), "detailed": .bool(false)])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let groupsInUse = Set(settings.compactMap { $0.objectValue?["group"]?.stringValue })
        XCTAssertTrue(groupsInUse.contains("judgment"), "This test is pointless if the DEBUG group is absent.")

        let tools = await service.tools
        let tool = try XCTUnwrap(tools.first)
        // Read the schema the way a client would: encoded, not through Swift accessors.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema))
        let properties = try XCTUnwrap((encoded as? [String: Any])?["properties"] as? [String: Any])
        let groupSchema = try XCTUnwrap(properties["group"] as? [String: Any])
        let advertised = try Set(XCTUnwrap(groupSchema["enum"] as? [String]))

        XCTAssertTrue(
            groupsInUse.isSubset(of: advertised),
            "Groups that exist but are not advertised: \(groupsInUse.subtracting(advertised).sorted())"
        )
        XCTAssertTrue(
            tool.description.contains("judgment"),
            "The tool description's group list is what an agent reads; it must name the group too."
        )
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

    // MARK: - The presence labels are not credentials

    /// Writing `not set` over a stored key used to install the literal string `not set` as
    /// the credential, because the changed-value gate compares the new value against the
    /// presence label the read returns, and `not set` differs from `set`. Every later
    /// request then sent `Authorization: Bearer not set` and failed 401, while a read still
    /// reported `set`. An operator clearing the key the intuitive way poisoned it silently.
    func testWritingTheAbsentLabelOverAStoredKeyIsRejectedRatherThanStored() async throws {
        let storage = InMemorySecureStore()
        JudgmentAPIKeyStore.storageForTesting = storage
        let service = try service()

        _ = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("judgment.api_key"),
            "value": .string("sk-systemone-abc")
        ])

        do {
            _ = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string("judgment.api_key"),
                "value": .string(JudgmentAPIKeyStore.absentLabel)
            ])
            XCTFail("expected the presence label to be rejected")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("empty"),
                "The error must point at the command that does work: '\(error)'"
            )
        }

        XCTAssertEqual(
            try storage.getPlainValue(for: .typeSafeSystemOneAPI),
            "sk-systemone-abc",
            "The stored key must survive a rejected write untouched."
        )
    }

    func testWritingThePresentLabelWithNoKeyStoredIsRejectedRatherThanStored() async throws {
        let storage = InMemorySecureStore()
        JudgmentAPIKeyStore.storageForTesting = storage
        let service = try service()

        do {
            _ = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string("judgment.api_key"),
                "value": .string(JudgmentAPIKeyStore.presentLabel)
            ])
            XCTFail("expected the presence label to be rejected")
        } catch {
            // Expected.
        }

        XCTAssertNil(try storage.getPlainValue(for: .typeSafeSystemOneAPI))
    }

    func testAPresenceLabelIsRejectedEvenWithSurroundingWhitespace() async throws {
        // The store trims before writing, so an untrimmed label would reach secure storage
        // as the trimmed sentinel.
        let storage = InMemorySecureStore()
        JudgmentAPIKeyStore.storageForTesting = storage
        let service = try service()

        do {
            _ = try await service.handleForTesting([
                "op": .string("set"),
                "key": .string("judgment.api_key"),
                "value": .string("  \(JudgmentAPIKeyStore.absentLabel)  ")
            ])
            XCTFail("expected the padded presence label to be rejected")
        } catch {
            // Expected.
        }

        XCTAssertNil(try storage.getPlainValue(for: .typeSafeSystemOneAPI))
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
