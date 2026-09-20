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

    /// Pins the actual defaults, which nothing could see while `setUp` wrote them first.
    /// A store over an empty suite is the only way to observe an unset value: reading back
    /// after writing `false` and `""` proves the write, not the default, and "off unless
    /// someone turns it on" is the claim the privacy note rests on.
    func testBothSettingsAreOffAndUnsetWhenNothingHasWrittenThem() throws {
        let suite = "JudgmentDebugSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JudgmentDebugSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let untouched = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )

        XCTAssertFalse(untouched.judgmentShadowEnabled(), "Shadow recording must be off until someone turns it on.")
        XCTAssertEqual(untouched.judgmentShadowLogFilePath(), "", "No directory override until someone sets one.")
    }

    func testShadowRecordingRoundTrips() {
        store.setJudgmentShadowEnabled(true)
        XCTAssertTrue(store.judgmentShadowEnabled())

        store.setJudgmentShadowEnabled(false)
        XCTAssertFalse(store.judgmentShadowEnabled())
    }

    func testTheLogPathRoundTrips() {
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
    /// The date axis is covered by `testTheWriterStartsANewFileWhenTheUTCDayChanges`.
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

    /// A run that crosses UTC midnight must start the next day's file rather than keep
    /// appending to the cached one. Without an injected clock this could not be tested, and
    /// a stale cache key would have silently filed a day's records under the day before.
    func testTheWriterStartsANewFileWhenTheUTCDayChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JudgmentShadowLogWriterRollover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.setJudgmentShadowLogFilePath(directory.path)

        // Deliberately not today's date. If the writer ignored the injected clock the
        // names would be today's, and the assertion would catch it rather than pass by
        // coincidence on whatever day the suite happens to run.
        let clock = MutableClock(now: Self.utc("2024-03-10T23:59:59Z"))
        let writer = JudgmentShadowLogWriter(now: { clock.now })

        writer.append(#"{"marker":"before-midnight"}"#)
        clock.now = Self.utc("2024-03-11T00:00:01Z")
        writer.append(#"{"marker":"after-midnight"}"#)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(
            names,
            ["judgment-shadow-20240310.jsonl", "judgment-shadow-20240311.jsonl"],
            "Two seconds apart across UTC midnight must produce two files, named for the injected clock."
        )
        for name in names {
            let lines = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n")
            XCTAssertEqual(lines.count, 1, "\(name) must hold exactly the record written on its own day.")
        }
    }

    private final class MutableClock: @unchecked Sendable {
        var now: Date
        init(now: Date) {
            self.now = now
        }
    }

    private static func utc(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso) ?? Date()
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
