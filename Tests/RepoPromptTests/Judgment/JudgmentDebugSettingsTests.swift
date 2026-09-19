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

    func testShadowRecordingIsOffUntilSomeoneTurnsItOn() {
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
}
