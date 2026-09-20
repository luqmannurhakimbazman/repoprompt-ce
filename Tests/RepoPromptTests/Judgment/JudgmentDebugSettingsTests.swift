@testable import RepoPromptApp
import XCTest

/// Covers the DEBUG-only shadow-mode settings. They follow the
/// `claudeRawEventLoggingEnabled` precedent: UserDefaults-backed, absent from release
/// builds, and off unless someone turns them on.
@MainActor
final class JudgmentDebugSettingsTests: XCTestCase {
    private var store: GlobalSettingsStore {
        GlobalSettingsStore.shared
    }

    private var originalEnabled = false
    private var originalPath = ""

    // `GlobalSettingsStore` uses a per-process random UserDefaults suite under unit test
    // (`GlobalSettingsManager.swift:334-339`), so a test that reached into
    // `UserDefaults.standard` would assert against a store nobody reads. These drive the
    // accessors only, and restore whatever they found.
    override func setUp() {
        super.setUp()
        originalEnabled = store.judgmentShadowEnabled()
        originalPath = store.judgmentShadowLogFilePath()
        store.setJudgmentShadowEnabled(false)
        store.setJudgmentShadowLogFilePath("")
    }

    override func tearDown() {
        store.setJudgmentShadowEnabled(originalEnabled)
        store.setJudgmentShadowLogFilePath(originalPath)
        super.tearDown()
    }

    /// Reads back what `setUp` wrote. It pins that writing `false` is observable, not that
    /// the setting defaults to off — `setUp` has already written the value by the time any
    /// test runs, so nothing here can see the default.
    func testWritingFalseIsReadBackAsFalse() {
        XCTAssertFalse(store.judgmentShadowEnabled())
    }

    func testShadowRecordingRoundTrips() {
        store.setJudgmentShadowEnabled(true)
        XCTAssertTrue(store.judgmentShadowEnabled())

        store.setJudgmentShadowEnabled(false)
        XCTAssertFalse(store.judgmentShadowEnabled())
    }

    func testTheLogPathDefaultsToEmptyAndRoundTrips() {
        XCTAssertEqual(store.judgmentShadowLogFilePath(), "")

        store.setJudgmentShadowLogFilePath("/tmp/repoprompt-ce-judgment-shadow")
        XCTAssertEqual(store.judgmentShadowLogFilePath(), "/tmp/repoprompt-ce-judgment-shadow")
    }

    func testAnEmptyOrBlankPathClearsTheOverride() {
        store.setJudgmentShadowLogFilePath("/tmp/repoprompt-ce-judgment-shadow")

        store.setJudgmentShadowLogFilePath("   ")

        XCTAssertEqual(store.judgmentShadowLogFilePath(), "")
    }

    // MARK: - The writer's resolved-URL cache

    /// The writer caches its resolved file URL under `(override, dateStamp)`. This covers
    /// the override axis: a mid-session settings edit must land the next line in the new
    /// directory rather than reusing the cached URL.
    ///
    /// The date axis is not covered. It needs `Date()` injected into
    /// `JudgmentShadowLogWriter`, which the writer does not offer, and a test cannot move
    /// the clock across UTC midnight without it.
    func testTheWriterFollowsAMidSessionDirectoryChange() throws {
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("JudgmentShadowLogWriterTests-first-\(UUID().uuidString)", isDirectory: true)
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("JudgmentShadowLogWriterTests-second-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let writer = JudgmentShadowLogWriter()

        store.setJudgmentShadowLogFilePath(first.path)
        writer.append(#"{"marker":"first"}"#)
        store.setJudgmentShadowLogFilePath(second.path)
        writer.append(#"{"marker":"second"}"#)

        XCTAssertEqual(try Self.appendedLines(in: first), [#"{"marker":"first"}"#])
        XCTAssertEqual(
            try Self.appendedLines(in: second),
            [#"{"marker":"second"}"#],
            "A cached URL that ignored the override change would have sent this line to the first directory."
        )
    }

    private static func appendedLines(in directory: URL) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        return try names.flatMap { name in
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
        }
    }
}
