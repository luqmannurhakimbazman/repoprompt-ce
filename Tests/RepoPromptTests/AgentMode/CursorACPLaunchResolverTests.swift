import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorACPLaunchResolverTests: XCTestCase {
    func testHealthyLegacyDoesNotDiscoverSecondaryEntrypoint() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: directory)
        let shellMarker = directory.appendingPathComponent("secondary-shell-lookup")
        let shell = try makeExecutable(named: "shell", in: directory, marker: shellMarker, output: "")
        let resolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": shell.path] },
            supplementalPathProvider: { $0 }
        )
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await resolver.probeSupport(for: config)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(try resolver.resolvedLaunch(for: config).command, try canonicalExecutablePath(executable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shellMarker.path))
    }

    func testDuplicateCanonicalLegacyIsProbedOnceBeforeDistinctFallback() async throws {
        let root = try makeTemporaryDirectory()
        let directories = try ["legacy", "current", "first", "second"].map { name in
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let legacy = try makeExecutable(named: "cursor-agent", in: directories[0])
        let current = try makeExecutable(named: "cursor-agent", in: directories[1])
        for directory in directories.suffix(2) {
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent("cursor-agent"), withDestinationURL: legacy
            )
        }
        // The same target also appears under the fallback name: deduplication spans stages.
        try FileManager.default.createSymbolicLink(
            at: directories[2].appendingPathComponent("agent"), withDestinationURL: legacy
        )
        try FileManager.default.createSymbolicLink(
            at: directories[3].appendingPathComponent("agent"), withDestinationURL: current
        )
        let path = directories.suffix(2).map(\.path).joined(separator: ":")
        let legacyPath = try canonicalExecutablePath(legacy)
        let currentPath = try canonicalExecutablePath(current)
        let probes = CursorProbeCommands()
        let resolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { launch, _, _, _ in
                await probes.record(launch.command)
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8), stderr: Data(),
                    status: launch.command == legacyPath ? 2 : 0, timedOut: false
                )
            }
        )
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await resolver.probeSupport(for: config)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(try resolver.resolvedLaunch(for: config).command, currentPath)
        let commands = await probes.commands
        XCTAssertEqual(commands, [legacyPath, currentPath])
    }

    func testInitialDiscoveryDoesNotConsumeCapabilityProbeBudget() async throws {
        try await assertDiscoveryPreservesProbeBudget(staleLegacy: false)
    }

    func testFallbackDiscoveryDoesNotConsumeCapabilityProbeBudget() async throws {
        try await assertDiscoveryPreservesProbeBudget(staleLegacy: true)
    }

    func testCancellationDuringDiscoveryDoesNotAdmitProducer() async throws {
        let root = try makeTemporaryDirectory()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = try makeExecutable(named: "cursor-agent", in: root)
        let enteredFIFO = root.appendingPathComponent("lookup-entered")
        let releaseFIFO = root.appendingPathComponent("lookup-release")
        for fifo in [enteredFIFO, releaseFIFO] {
            guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        }
        let enteredDescriptor = open(enteredFIFO.path, O_RDWR | O_NONBLOCK)
        guard enteredDescriptor >= 0 else { throw POSIXError(.EIO) }
        let entered = expectation(description: "Shell lookup reached the release barrier")
        let reader = DispatchSource.makeReadSource(fileDescriptor: enteredDescriptor, queue: .global())
        reader.setEventHandler {
            var byte: UInt8 = 0
            if Darwin.read(enteredDescriptor, &byte, 1) == 1 { entered.fulfill() }
        }
        reader.setCancelHandler { close(enteredDescriptor) }
        reader.resume()
        defer { reader.cancel() }
        let releaseDescriptor = open(releaseFIFO.path, O_RDWR | O_NONBLOCK)
        guard releaseDescriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(releaseDescriptor) }
        let completedMarker = root.appendingPathComponent("lookup-completed")
        let shell = try makeExecutable(named: "shell", in: root)
        try """
        #!/bin/sh
        printf '1' > '\(enteredFIFO.path)'
        IFS= read -r release < '\(releaseFIFO.path)'
        printf '1' > '\(completedMarker.path)'
        printf '%s\\n' '__RP_BEGIN__' '\(executable.path)' '__RP_END__'
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let calls = CursorProbeCallCounter()
        let resolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": bin.path, "SHELL": shell.path] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                _ = await calls.nextCall()
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8), stderr: Data(), status: 0, timedOut: false
                )
            }
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])
        let supportTask = Task { try await resolver.probeSupport(for: config) }

        // This timeout is a deadlock guard, not a performance oracle.
        await fulfillment(of: [entered], timeout: 30)
        supportTask.cancel()
        var releaseByte: UInt8 = 10
        XCTAssertEqual(Darwin.write(releaseDescriptor, &releaseByte, 1), 1)
        do {
            _ = try await supportTask.value
            XCTFail("Expected cancellation after shell discovery")
        } catch is CancellationError {
            // Expected.
        }
        await resolver.waitForProbeAttemptSettlementForTesting()

        XCTAssertTrue(FileManager.default.fileExists(atPath: completedMarker.path))
        let callCount = await calls.count()
        XCTAssertEqual(callCount, 0)
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testProductionDefaultFallsBackToVerifiedAgentAlias() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let packageDirectory = rootDirectory.appendingPathComponent("cursor-package", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let cursorExecutable = try makeExecutable(named: "cursor-agent", in: packageDirectory)
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("agent"),
            withDestinationURL: cursorExecutable
        )
        let resolver = makeResolver(path: binDirectory.path)
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await resolver.probeSupport(for: config)
        guard support == .supported else {
            return XCTFail("Expected supported Cursor entrypoint: \(support)")
        }
        let launch = try resolver.resolvedLaunch(for: config)

        XCTAssertEqual(launch.command, try canonicalExecutablePath(cursorExecutable))
    }

    func testProductionDefaultRejectsUnverifiedGenericAgentBeforeProbe() async throws {
        let directory = try makeTemporaryDirectory()
        let probeMarker = directory.appendingPathComponent("generic-agent-probed")
        _ = try makeExecutable(
            named: "agent",
            in: directory,
            marker: probeMarker,
            output: "Usage: agent acp\nStart the Cursor Agent as an ACP (Agent Client Protocol) server"
        )
        let resolver = makeResolver(path: directory.path)
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await resolver.probeSupport(for: config)

        guard case .unsupported = support else {
            return XCTFail("Expected an unverified generic agent executable to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeMarker.path))
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testProductionDefaultRejectsCursorAgentSymlinkToGenericAgentBeforeProbe() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let packageDirectory = rootDirectory.appendingPathComponent("unrelated-package", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let probeMarker = rootDirectory.appendingPathComponent("generic-agent-probed")
        let genericAgent = try makeExecutable(
            named: "agent",
            in: packageDirectory,
            marker: probeMarker,
            output: "Usage: agent acp\nStart the Cursor Agent as an ACP (Agent Client Protocol) server"
        )
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("cursor-agent"),
            withDestinationURL: genericAgent
        )
        let resolver = makeResolver(path: binDirectory.path)
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await resolver.probeSupport(for: config)

        guard case .unsupported = support else {
            return XCTFail("Expected cursor-agent resolving to a generic agent executable to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeMarker.path))
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testProductionDefaultFallsThroughStaleCursorAgentToVerifiedAgentAlias() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let legacyDirectory = rootDirectory.appendingPathComponent("legacy", isDirectory: true)
        let currentDirectory = rootDirectory.appendingPathComponent("current", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let legacyProbeMarker = rootDirectory.appendingPathComponent("legacy-probed")
        let legacyExecutable = try makeExecutable(
            named: "cursor-agent",
            in: legacyDirectory,
            marker: legacyProbeMarker,
            output: "Usage: cursor-agent [OPTIONS]"
        )
        let currentExecutable = try makeExecutable(named: "cursor-agent", in: currentDirectory)
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("cursor-agent"),
            withDestinationURL: legacyExecutable
        )
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("agent"),
            withDestinationURL: currentExecutable
        )
        let resolver = makeResolver(path: binDirectory.path)
        let config = CursorAgentConfig(additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)
        guard support == .supported else {
            return XCTFail("Expected supported Cursor entrypoint: \(support)")
        }
        let launch = try resolver.resolvedLaunch(for: config)

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyProbeMarker.path))
        XCTAssertEqual(launch.command, try canonicalExecutablePath(currentExecutable))
    }

    func testCapabilityProbeRejectsTimedOutZeroStatusAndDoesNotCacheLaunch() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "cursor-agent", in: directory)
        let resolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: true
                )
            }
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)

        guard case .unsupported = support else {
            return XCTFail("Expected a timed-out probe to be unsupported")
        }
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case CursorACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCapabilityProbeReservesTimeoutCleanupWithinAggregateDeadline() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        let legacyDirectory = rootDirectory.appendingPathComponent("legacy", isDirectory: true)
        let currentDirectory = rootDirectory.appendingPathComponent("current", isDirectory: true)
        let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let legacyExecutable = try makeExecutable(named: "cursor-agent", in: legacyDirectory)
        let currentExecutable = try makeExecutable(named: "cursor-agent", in: currentDirectory)
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("cursor-agent"),
            withDestinationURL: legacyExecutable
        )
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("agent"),
            withDestinationURL: currentExecutable
        )
        let timeline = CursorProbeTimeline(nowValues: [0, 1, 10, 10, 10])
        let deadline = CursorProbeDeadlineBarrier()
        let resolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": binDirectory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, timeout, timeoutCleanupPolicy in
                timeline.record(timeout: timeout, cleanupAllowance: timeoutCleanupPolicy.maximumDuration)
                return CLIProcessRunner.Result(stdout: Data(), stderr: Data(), status: 2, timedOut: false)
            },
            nowProvider: { timeline.nextNow() },
            deadlineWaiter: { _ in await deadline.wait() },
            aggregateProbeTimeout: 10
        )

        let support = try await resolver.probeSupport(for: CursorAgentConfig(additionalPathHints: []))

        guard case .unsupported = support else {
            return XCTFail("Expected aggregate deadline exhaustion to be unsupported")
        }
        XCTAssertEqual(timeline.recordedTimeouts(), [6])
        XCTAssertEqual(timeline.recordedCleanupAllowances(), [3])
    }

    func testCapabilityProbeDoesNotCacheSuccessAfterClockDeadlineBeforeTimerFires() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "cursor-agent", in: directory)
        let timeline = CursorProbeTimeline(nowValues: [0, 0, 10])
        let deadline = CursorProbeDeadlineBarrier()
        let resolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: false
                )
            },
            nowProvider: { timeline.nextNow() },
            deadlineWaiter: { _ in await deadline.wait() },
            aggregateProbeTimeout: 10
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)

        guard case let .unsupported(reason) = support else {
            return XCTFail("Expected an expired clock to reject the successful producer result")
        }
        XCTAssertTrue(reason.contains("aggregate timeout"))
        let timerWasSignaled = await deadline.wasSignaled()
        XCTAssertFalse(timerWasSignaled)
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))
    }

    func testProductionProbeTimeoutRetainsSharedOwnershipUntilSettlementAndRecovers() async throws {
        let directory = try makeTemporaryDirectory()
        let enteredFIFO = directory.appendingPathComponent("production-probe-entered")
        guard mkfifo(enteredFIFO.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let enteredDescriptor = open(enteredFIFO.path, O_RDWR | O_NONBLOCK)
        guard enteredDescriptor >= 0 else { throw POSIXError(.EIO) }
        let entered = expectation(description: "Production probe process entered")
        let enteredReader = DispatchSource.makeReadSource(fileDescriptor: enteredDescriptor, queue: .global())
        enteredReader.setEventHandler {
            var byte: UInt8 = 0
            if Darwin.read(enteredDescriptor, &byte, 1) == 1 {
                entered.fulfill()
            }
        }
        enteredReader.setCancelHandler { close(enteredDescriptor) }
        enteredReader.resume()
        defer { enteredReader.cancel() }

        let invocationLog = directory.appendingPathComponent("production-probe-invocations")
        let recoveryMarker = directory.appendingPathComponent("production-probe-recovery")
        let forceExitMarker = directory.appendingPathComponent("production-probe-force-exit")
        let executable = directory.appendingPathComponent("cursor-agent")
        try """
        #!/bin/sh
        printf '1\\n' >> '\(invocationLog.path)'
        if [ -f '\(recoveryMarker.path)' ]; then
          printf '%s\\n' 'Cursor Agent ACP support'
          exit 0
        fi
        trap '' TERM
        printf '1' > '\(enteredFIFO.path)'
        while [ ! -f '\(forceExitMarker.path)' ]; do sleep 1; done
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let previousDiagnosticsOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
        AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
        let diagnosticBaseline = Set(AgentModePerfDiagnostics.recentMetricLinesSnapshot(limit: 1000))
        defer { AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousDiagnosticsOverride) }

        let deadline = CursorProbeDeadlineBarrier()
        let settlementGate = CursorProbeProducerBarrier()
        let settlementReached = expectation(description: "Production probe runner reached settlement gate")
        let firstResolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            deadlineWaiter: { _ in await deadline.wait() },
            aggregateProbeTimeout: 3600
        )
        firstResolver.setBeforeProbeProducerSettlementForTesting {
            settlementReached.fulfill()
            await settlementGate.waitForRelease()
        }
        let secondResolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            aggregateProbeTimeout: 3600,
            sharingProbeOwnershipWith: firstResolver
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])
        let forceFixtureExit: @Sendable () async -> Void = {
            try? Data().write(to: forceExitMarker)
            await deadline.signal()
            await settlementGate.release()
        }
        let firstProbeCompleted = expectation(description: "Initial production probe completed")
        let firstProbe = Task<ACPSupportResult, Error> {
            defer { firstProbeCompleted.fulfill() }
            return try await firstResolver.probeSupport(for: config)
        }
        defer {
            firstProbe.cancel()
            try? Data().write(to: forceExitMarker)
            Task {
                await deadline.signal()
                await settlementGate.release()
            }
        }

        do {
            // These XCTest deadlines are deadlock guards, not performance assertions.
            try await requireCursorProbeExpectation(entered, description: "production probe process entry")
            let deadlineEntered = expectation(description: "Production probe deadline waiter entered")
            let deadlineEntryTask = Task<Void, Error> {
                defer { deadlineEntered.fulfill() }
                await deadline.waitUntilEntered()
                try Task.checkCancellation()
            }
            _ = try await boundedCursorProbeValue(
                of: deadlineEntryTask,
                completion: deadlineEntered,
                description: "production probe deadline waiter",
                onTimeout: forceFixtureExit
            )
            await deadline.signal()

            let firstSupport = try await boundedCursorProbeValue(
                of: firstProbe,
                completion: firstProbeCompleted,
                description: "initial production probe result",
                onTimeout: forceFixtureExit
            )
            guard case let .unsupported(firstReason) = firstSupport else {
                throw CursorProbeRegressionFailure.unexpectedResult(
                    "Expected the controlled deadline to retire the production probe"
                )
            }
            XCTAssertTrue(firstReason.contains("aggregate timeout"))

            let pendingCompleted = expectation(description: "Sibling pending probe completed")
            let pendingProbe = Task<ACPSupportResult, Error> {
                defer { pendingCompleted.fulfill() }
                return try await secondResolver.probeSupport(for: config)
            }
            let pendingSupport = try await boundedCursorProbeValue(
                of: pendingProbe,
                completion: pendingCompleted,
                description: "sibling cleanup-pending probe",
                onTimeout: forceFixtureExit
            )
            guard case let .unsupported(pendingReason) = pendingSupport else {
                throw CursorProbeRegressionFailure.unexpectedResult(
                    "Expected the sibling resolver to observe retained cleanup ownership"
                )
            }
            XCTAssertTrue(pendingReason.contains("cleanup is still pending"))
            XCTAssertEqual(try probeInvocationCount(at: invocationLog), 1)

            try await requireCursorProbeExpectation(
                settlementReached,
                description: "production probe runner settlement gate",
                onTimeout: forceFixtureExit
            )
            try Data().write(to: recoveryMarker)
            await settlementGate.release()
            let settlementCompleted = expectation(description: "Production probe ownership settled")
            let settlementTask = Task<Void, Error> {
                defer { settlementCompleted.fulfill() }
                await firstResolver.waitForProbeAttemptSettlementForTesting()
                try Task.checkCancellation()
            }
            _ = try await boundedCursorProbeValue(
                of: settlementTask,
                completion: settlementCompleted,
                description: "production probe ownership settlement",
                onTimeout: forceFixtureExit
            )
            XCTAssertThrowsError(try firstResolver.resolvedLaunch(for: config))

            let recoveredCompleted = expectation(description: "Recovered production probe completed")
            let recoveredProbe = Task<ACPSupportResult, Error> {
                defer { recoveredCompleted.fulfill() }
                return try await secondResolver.probeSupport(for: config)
            }
            let recoveredSupport = try await boundedCursorProbeValue(
                of: recoveredProbe,
                completion: recoveredCompleted,
                description: "recovered production probe",
                onTimeout: forceFixtureExit
            )
            XCTAssertEqual(recoveredSupport, .supported)
        } catch {
            let operationError = error
            firstProbe.cancel()
            await forceFixtureExit()
            try await requireCursorProbeTaskCompletion(
                firstProbe,
                description: "initial production probe failure cleanup"
            )
            let cleanupCompleted = expectation(description: "Production probe failure cleanup settled")
            let cleanupTask = Task<Void, Error> {
                defer { cleanupCompleted.fulfill() }
                await firstResolver.waitForProbeAttemptSettlementForTesting()
                try Task.checkCancellation()
            }
            _ = try await boundedCursorProbeValue(
                of: cleanupTask,
                completion: cleanupCompleted,
                description: "production probe failure cleanup settlement",
                onTimeout: forceFixtureExit
            )
            throw operationError
        }
        XCTAssertEqual(try probeInvocationCount(at: invocationLog), 2)
        XCTAssertEqual(
            try secondResolver.resolvedLaunch(for: config).command,
            try canonicalExecutablePath(executable)
        )

        let diagnosticLines = AgentModePerfDiagnostics.recentMetricLinesSnapshot(limit: 1000)
            .filter { !diagnosticBaseline.contains($0) }
        for event in [
            "provider.cursor.preflight.wait_started",
            "provider.cursor.preflight.lock_acquired",
            "provider.cursor.preflight.attempt_started",
            "provider.cursor.preflight.logical_timeout",
            "provider.cursor.preflight.cleanup_pending_rejected",
            "provider.cursor.preflight.producer_settled",
            "provider.cursor.preflight.ownership_released",
            "provider.cursor.preflight.finished"
        ] {
            XCTAssertTrue(
                diagnosticLines.contains(where: { $0.contains(event) }),
                "Expected diagnostics to contain \(event)"
            )
        }
        let attemptRecords = diagnosticLines.compactMap {
            cursorProbeDiagnosticFields(in: $0, event: "provider.cursor.preflight.attempt_started")
        }
        XCTAssertEqual(attemptRecords.count, 2)
        let attemptIDs = try attemptRecords.map { fields in
            XCTAssertEqual(fields["source"], "test")
            return try XCTUnwrap(fields["attempt_id"])
        }
        XCTAssertEqual(Set(attemptIDs).count, 2)

        let cleanupRecords = diagnosticLines.compactMap {
            cursorProbeDiagnosticFields(in: $0, event: "provider.cursor.preflight.cleanup_pending_rejected")
        }
        XCTAssertEqual(cleanupRecords.count, 1)
        let cleanupRecord = try XCTUnwrap(cleanupRecords.first)
        XCTAssertEqual(cleanupRecord["source"], "test")
        XCTAssertEqual(cleanupRecord["blocking_source"], "test")
        XCTAssertEqual(cleanupRecord["blocking_attempt_id"], attemptIDs.first)

        let releaseRecords = diagnosticLines.compactMap {
            cursorProbeDiagnosticFields(in: $0, event: "provider.cursor.preflight.ownership_released")
        }
        for attemptID in attemptIDs {
            XCTAssertEqual(releaseRecords.count(where: { $0["attempt_id"] == attemptID }), 1)
        }
    }

    func testCapabilityProbeTimeoutRejectsNewResolverUntilLateProducerSettles() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: directory)
        let producer = CursorProbeProducerBarrier()
        let firstCalls = CursorProbeCallCounter()
        let secondCalls = CursorProbeCallCounter()
        let firstDeadline = CursorProbeDeadlineBarrier()
        let secondDeadline = CursorProbeDeadlineBarrier()
        let firstResolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                let call = await firstCalls.nextCall()
                if call == 1 {
                    await producer.enter()
                    await withTaskCancellationHandler(operation: {
                        await producer.waitForRelease()
                    }, onCancel: {
                        Task { await producer.recordCancellation() }
                    })
                    await producer.recordReturned()
                }
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: false
                )
            },
            nowProvider: { 0 },
            deadlineWaiter: { _ in await firstDeadline.wait() },
            aggregateProbeTimeout: 10
        )
        let secondResolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                await secondCalls.nextCall()
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: false
                )
            },
            nowProvider: { 0 },
            deadlineWaiter: { _ in await secondDeadline.wait() },
            aggregateProbeTimeout: 10,
            sharingProbeOwnershipWith: firstResolver
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])
        let firstProbe = Task { try await firstResolver.probeSupport(for: config) }

        await producer.waitUntilEntered()
        await firstDeadline.waitUntilEntered()
        await firstDeadline.signal()

        let firstSupport = try await firstProbe.value
        guard case let .unsupported(reason) = firstSupport else {
            return XCTFail("Expected the aggregate deadline to retire the logical probe")
        }
        XCTAssertTrue(reason.contains("aggregate timeout"))
        await producer.waitUntilCancellation()

        let pendingSupport = try await secondResolver.probeSupport(for: config)
        guard case let .unsupported(pendingReason) = pendingSupport else {
            return XCTFail("Expected a retry to be rejected while the producer drains")
        }
        XCTAssertTrue(pendingReason.contains("cleanup is still pending"))
        let firstCallCount = await firstCalls.count()
        XCTAssertEqual(firstCallCount, 1)
        let pendingCallCount = await secondCalls.count()
        XCTAssertEqual(pendingCallCount, 0)

        await producer.release()
        await producer.waitUntilReturned()
        await firstResolver.waitForProbeAttemptSettlementForTesting()
        XCTAssertThrowsError(try secondResolver.resolvedLaunch(for: config))

        let recoveredSupport = try await secondResolver.probeSupport(for: config)
        XCTAssertEqual(recoveredSupport, .supported)
        let recoveredCallCount = await secondCalls.count()
        XCTAssertEqual(recoveredCallCount, 1)
        let recoveredLaunch = try secondResolver.resolvedLaunch(for: config)
        XCTAssertEqual(recoveredLaunch.command, try canonicalExecutablePath(executable))
    }

    func testCapabilityProbeCancellationDrainsProducerBeforeRecovery() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: directory)
        let producer = CursorProbeProducerBarrier()
        let calls = CursorProbeCallCounter()
        let firstDeadline = CursorProbeDeadlineBarrier()
        let secondDeadline = CursorProbeDeadlineBarrier()
        let deadlines = CursorProbeDeadlineRouter([firstDeadline, secondDeadline])
        let resolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": directory.path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in
                let call = await calls.nextCall()
                if call == 1 {
                    await producer.enter()
                    await withTaskCancellationHandler(operation: {
                        await producer.waitForRelease()
                    }, onCancel: {
                        Task { await producer.recordCancellation() }
                    })
                    await producer.recordReturned()
                }
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: false
                )
            },
            nowProvider: { 0 },
            deadlineWaiter: { _ in await deadlines.wait() },
            aggregateProbeTimeout: 10
        )
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])
        let firstProbe = Task { try await resolver.probeSupport(for: config) }

        await producer.waitUntilEntered()
        firstProbe.cancel()
        do {
            _ = try await firstProbe.value
            XCTFail("Expected cancellation to propagate from the logical probe")
        } catch is CancellationError {
            // Expected: the producer remains owned independently of this task.
        }
        await producer.waitUntilCancellation()

        let pendingSupport = try await resolver.probeSupport(for: config)
        guard case let .unsupported(pendingReason) = pendingSupport else {
            return XCTFail("Expected a retry to be rejected while the canceled producer drains")
        }
        XCTAssertTrue(pendingReason.contains("cleanup is still pending"))
        let pendingCallCount = await calls.count()
        XCTAssertEqual(pendingCallCount, 1)

        await producer.release()
        await producer.waitUntilReturned()
        await resolver.waitForProbeAttemptSettlementForTesting()
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config))

        let recoveredSupport = try await resolver.probeSupport(for: config)
        XCTAssertEqual(recoveredSupport, .supported)
        let recoveredCallCount = await calls.count()
        XCTAssertEqual(recoveredCallCount, 2)
        let recoveredLaunch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(recoveredLaunch.command, try canonicalExecutablePath(executable))
    }

    private func assertDiscoveryPreservesProbeBudget(staleLegacy: Bool) async throws {
        let root = try makeTemporaryDirectory()
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("current", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        for directory in [legacyDirectory, currentDirectory, binDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let legacy = try makeExecutable(named: "cursor-agent", in: legacyDirectory)
        let current = try makeExecutable(named: "cursor-agent", in: currentDirectory)
        let alias = (staleLegacy ? root : binDirectory).appendingPathComponent("agent")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: current)
        if staleLegacy {
            try FileManager.default.createSymbolicLink(
                at: binDirectory.appendingPathComponent("cursor-agent"), withDestinationURL: legacy
            )
        }
        let lookupMarker = root.appendingPathComponent("shell-lookup")
        let shell = try makeExecutable(
            named: "shell", in: root, marker: lookupMarker,
            output: staleLegacy ? "__RP_BEGIN__\n\(alias.path)\n__RP_END__" : ""
        )
        let legacyPath = try canonicalExecutablePath(legacy)
        let currentPath = try canonicalExecutablePath(current)
        let probes = CursorProbeCommands()
        let clock = CursorDiscoveryClock(lookupMarker: lookupMarker)
        let resolver = CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": binDirectory.path, "SHELL": shell.path] },
            supplementalPathProvider: { $0 },
            probeRunner: { launch, _, timeout, _ in
                await probes.record(launch.command, timeout: timeout)
                if launch.command == legacyPath { clock.advance(by: 6) }
                return CLIProcessRunner.Result(
                    stdout: Data("Cursor Agent ACP support".utf8), stderr: Data(),
                    status: launch.command == legacyPath ? 2 : 0, timedOut: false
                )
            },
            // Model slow discovery without sleeps or a host-dependent duration assertion.
            nowProvider: { clock.now() },
            deadlineWaiter: { _ in await CursorProbeDeadlineBarrier().wait() },
            aggregateProbeTimeout: 10
        )
        let config = CursorAgentConfig(additionalPathHints: [], includeRepoPromptMCPServer: false)

        let support = try await resolver.probeSupport(for: config)

        XCTAssertTrue(FileManager.default.fileExists(atPath: lookupMarker.path))
        XCTAssertEqual(support, .supported)
        let commands = await probes.commands
        XCTAssertEqual(commands, staleLegacy ? [legacyPath, currentPath] : [currentPath])
        let timeouts = await probes.timeouts
        XCTAssertEqual(timeouts, staleLegacy ? [7, 1] : [7])
        XCTAssertEqual(try resolver.resolvedLaunch(for: config).command, currentPath)
    }

    private func requireCursorProbeExpectation(
        _ expectation: XCTestExpectation,
        description: String,
        timeout: TimeInterval = 30,
        onTimeout: @escaping @Sendable () async -> Void = {}
    ) async throws {
        guard await XCTWaiter.fulfillment(of: [expectation], timeout: timeout) == .completed else {
            await onTimeout()
            throw CursorProbeRegressionFailure.operationTimedOut(description)
        }
    }

    private func boundedCursorProbeValue<Value: Sendable>(
        of task: Task<Value, Error>,
        completion: XCTestExpectation,
        description: String,
        timeout: TimeInterval = 30,
        onTimeout: @escaping @Sendable () async -> Void
    ) async throws -> Value {
        guard await XCTWaiter.fulfillment(of: [completion], timeout: timeout) == .completed else {
            task.cancel()
            await onTimeout()
            try await requireCursorProbeTaskCompletion(
                task,
                description: "\(description) cleanup",
                timeout: timeout
            )
            throw CursorProbeRegressionFailure.operationTimedOut(description)
        }
        return try await task.value
    }

    private func requireCursorProbeTaskCompletion(
        _ task: Task<some Sendable, Error>,
        description: String,
        timeout: TimeInterval = 30
    ) async throws {
        let completed = XCTestExpectation(description: description)
        Task {
            _ = await task.result
            completed.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [completed], timeout: timeout) == .completed else {
            throw CursorProbeRegressionFailure.cleanupTimedOut(description)
        }
    }

    private func cursorProbeDiagnosticFields(in line: String, event: String) -> [String: String]? {
        guard let eventRange = line.range(of: "\(event) ") else { return nil }
        return line[eventRange.upperBound...].split(separator: " ").reduce(into: [:]) { fields, pair in
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else { return }
            fields[String(components[0])] = String(components[1])
        }
    }

    private func probeInvocationCount(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .count
    }

    private func makeResolver(path: String) -> CursorACPLaunchResolver {
        CursorACPLaunchResolver(
            environmentProvider: { _ in ["PATH": path, "SHELL": "/bin/false"] },
            supplementalPathProvider: { $0 }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "CursorACPLaunchResolverTests")
    }

    private func canonicalExecutablePath(_ url: URL) throws -> String {
        try XCTUnwrap(FileSystemService.realpathString(url.path))
    }

    @discardableResult
    private func makeExecutable(
        named name: String,
        in directory: URL,
        marker: URL? = nil,
        output: String = "Cursor Agent ACP support"
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        var lines = ["#!/bin/sh"]
        if let marker {
            lines.append("printf '%s' \"$0\" > '\(marker.path)'")
        }
        lines.append("printf '%s\\n' '\(output)'")
        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}

private enum CursorProbeRegressionFailure: LocalizedError {
    case operationTimedOut(String)
    case cleanupTimedOut(String)
    case unexpectedResult(String)

    var errorDescription: String? {
        switch self {
        case let .operationTimedOut(description):
            "Timed out waiting for \(description)."
        case let .cleanupTimedOut(description):
            "Timed out waiting for \(description); the production probe task may not have reaped its subprocess."
        case let .unexpectedResult(description):
            description
        }
    }
}

private final class CursorProbeTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var nowValues: [TimeInterval]
    private var timeouts: [TimeInterval] = []
    private var cleanupAllowances: [TimeInterval] = []

    init(nowValues: [TimeInterval]) {
        self.nowValues = nowValues
    }

    func nextNow() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return nowValues.removeFirst()
    }

    func record(timeout: TimeInterval, cleanupAllowance: TimeInterval) {
        lock.lock()
        timeouts.append(timeout)
        cleanupAllowances.append(cleanupAllowance)
        lock.unlock()
    }

    func recordedTimeouts() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return timeouts
    }

    func recordedCleanupAllowances() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return cleanupAllowances
    }
}

private actor CursorProbeCallCounter {
    private var callCount = 0

    func nextCall() -> Int {
        callCount += 1
        return callCount
    }

    func count() -> Int {
        callCount
    }
}

private actor CursorProbeProducerBarrier {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var returnedContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isReleased = false
    private var cancellationRequested = false
    private var hasReturned = false

    func enter() {
        guard !hasEntered else { return }
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            if hasEntered {
                continuation.resume()
            } else {
                enteredContinuation = continuation
            }
        }
    }

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func recordCancellation() {
        guard !cancellationRequested else { return }
        cancellationRequested = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func waitUntilCancellation() async {
        guard !cancellationRequested else { return }
        await withCheckedContinuation { continuation in
            if cancellationRequested {
                continuation.resume()
            } else {
                cancellationContinuation = continuation
            }
        }
    }

    func recordReturned() {
        guard !hasReturned else { return }
        hasReturned = true
        returnedContinuation?.resume()
        returnedContinuation = nil
    }

    func waitUntilReturned() async {
        guard !hasReturned else { return }
        await withCheckedContinuation { continuation in
            if hasReturned {
                continuation.resume()
            } else {
                returnedContinuation = continuation
            }
        }
    }
}

private actor CursorProbeDeadlineBarrier {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isOpen = false

    func wait() async {
        if !hasEntered {
            hasEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
        guard !isOpen else { return }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                } else {
                    waitContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter() }
        })
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            if hasEntered {
                continuation.resume()
            } else {
                enteredContinuation = continuation
            }
        }
    }

    func signal() {
        guard !isOpen else { return }
        isOpen = true
        waitContinuation?.resume()
        waitContinuation = nil
    }

    func wasSignaled() -> Bool {
        isOpen
    }

    private func cancelWaiter() {
        waitContinuation?.resume()
        waitContinuation = nil
    }
}

private actor CursorProbeDeadlineRouter {
    private var barriers: [CursorProbeDeadlineBarrier]

    init(_ barriers: [CursorProbeDeadlineBarrier]) {
        self.barriers = barriers
    }

    func wait() async {
        guard !barriers.isEmpty else { return }
        let barrier = barriers.removeFirst()
        await barrier.wait()
    }
}

private actor CursorProbeCommands {
    private(set) var commands: [String] = []
    private(set) var timeouts: [TimeInterval] = []

    func record(_ command: String, timeout: TimeInterval? = nil) {
        commands.append(command)
        if let timeout { timeouts.append(timeout) }
    }
}

private final class CursorDiscoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private let lookupMarker: URL
    private var elapsedProbeTime: TimeInterval = 0

    init(lookupMarker: URL) {
        self.lookupMarker = lookupMarker
    }

    func advance(by duration: TimeInterval) {
        lock.lock()
        elapsedProbeTime += duration
        lock.unlock()
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return elapsedProbeTime + (FileManager.default.fileExists(atPath: lookupMarker.path) ? 20 : 0)
    }
}
