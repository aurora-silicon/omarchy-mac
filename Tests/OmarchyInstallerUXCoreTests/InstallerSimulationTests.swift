#if DEBUG && os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import XCTest
  @testable import OmarchyInstallerUXCore

  @MainActor
  final class InstallerSimulationTests: XCTestCase {
    func testReserveColorPreviewCrossesBoundaryAndClearsAgain() async {
      let session = InstallerSession(
        environment: InstallerSimulationEnvironment(scenario: .reserveColorPreview, delay: .zero))
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      for size: UInt64 in [42_000_000_000, 43_000_000_000, 42_000_000_000] {
        await session.replan(omarchyBytes: size)
        guard case .planReview(let plan, _) = session.phase else {
          return XCTFail("Expected disk review")
        }
        XCTAssertEqual(plan.omarchyBytes, size)
        XCTAssertEqual(plan.macOSSpaceCaution(for: size) != nil, size > 42_000_000_000)
      }
    }

    func testMacOSAlreadyBelowItsReserveIsRefusedWithTheDeficit() async {
      // As in the planner: no space can be taken from macOS, so the shortfall
      // is Omarchy's 40 GB minimum plus the 3 GB below the 38 GB reserve.
      let session = InstallerSession(
        environment: InstallerSimulationEnvironment(scenario: .lowReserve, delay: .zero))
      await session.inspect()
      await session.continueToPlan()
      guard case .failed(let failure) = session.phase else {
        return XCTFail("Expected a refusal")
      }
      XCTAssertEqual(failure.headline, "Free up at least 43 GB to install Omarchy")
      XCTAssertFalse(session.hasExecutionStarted)
    }

    func testTightDiskSimulationKeepsHardMacOSReserve() async {
      let session = InstallerSession(
        environment: InstallerSimulationEnvironment(scenario: .tightDisk, delay: .zero))
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      await session.replan(omarchyBytes: 55_000_000_000)
      guard case .planReview(let plan, _) = session.phase else {
        return XCTFail("Expected disk review")
      }
      XCTAssertEqual(plan.maximumBytes, 42_000_000_000)
      XCTAssertEqual(plan.omarchyBytes, plan.maximumBytes)
      XCTAssertEqual(plan.macOSFreeBeforeAllocationBytes! - plan.omarchyBytes, 38_000_000_000)
    }

    func testGenericAndQuantifiedPlanningFailuresRemainDistinct() async {
      for (scenario, headline) in [
        (InstallerSimulationScenario.planFailure, "There isn’t enough usable disk space"),
        (.insufficientSpace, "Free up at least 6 GB to install Omarchy"),
      ] {
        let session = InstallerSession(
          environment: InstallerSimulationEnvironment(scenario: scenario, delay: .zero))
        await session.inspect()
        await session.continueToPlan()
        guard case .failed(let failure) = session.phase else { return XCTFail(scenario.title) }
        XCTAssertEqual(failure.headline, headline)
        XCTAssertFalse(session.hasExecutionStarted)
      }
    }

    func testDiskAlignmentDoesNotClaimSelected180GBIsACapacityLimit() async throws {
      let environment = InstallerSimulationEnvironment(scenario: .allocationAligned, delay: .zero)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      await session.replan(omarchyBytes: 180_000_000_000)
      guard case .planReview(let plan, let acknowledged) = session.phase else {
        return XCTFail("Expected disk review")
      }
      XCTAssertNotEqual(plan.omarchyBytes, 180_000_000_000)
      XCTAssertEqual(DiskSizeInput().display(plan.omarchyBytes), "180")
      XCTAssertNil(session.allocationNotice)
      XCTAssertFalse(acknowledged)
    }

    func testTheThreeChannelStatesPreviewDistinctly() async throws {
      let expected: [(InstallerSimulationScenario, ReleaseChannelAvailability, String, String)] = [
        (
          .noMacRelease, .noRelease, "Edge — No Mac release yet",
          "No Mac release on this channel yet"
        ),
        (
          .modelNotOnChannel,
          .modelUnavailable(
            supportedDeviceIdentifiers: InstallerSimulationEnvironment.simulatedCatalogDevices),
          "Edge — Not available for this Mac", PlainLanguage.blockedHeadline
        ),
        (
          .channelUnreachable, .checkFailed(.network), "Edge — Couldn’t load",
          "This channel’s release list wasn’t found"
        ),
      ]
      for (scenario, availability, menuItem, headline) in expected {
        let session = InstallerSession(
          environment: InstallerSimulationEnvironment(scenario: scenario, delay: .zero))
        await session.inspect()
        await session.refreshChannelAvailability()
        XCTAssertEqual(session.channelAvailability[.edge], availability, scenario.title)
        XCTAssertEqual(session.channelAvailability[.stable], .noRelease, scenario.title)
        let item = PlainLanguage.channelMenuItem(.edge, availability: availability)
        XCTAssertEqual(item, menuItem, scenario.title)
        await session.continueToPlan()
        guard case .failed(let failure) = session.phase else {
          return XCTFail(scenario.title)
        }
        XCTAssertEqual(failure.headline, headline, scenario.title)
      }
    }

    func testSyntheticJournalPassesRealDecoder() throws {
      let data = InstallerSimulationEnvironment.journalLines.reduce(into: Data()) { $0.append($1) }
      let transcript = try AppleInstallerTrustCore().validateEngineTranscript(data)
      XCTAssertEqual(transcript.checkpoints.count, 3)
      XCTAssertEqual(transcript.completion, .awaitingRecovery)
    }

    func testEveryScenarioReachesItsExpectedOutcome() async throws {
      for scenario in InstallerSimulationScenario.allCases {
        let environment = InstallerSimulationEnvironment(scenario: scenario, delay: .zero)
        XCTAssertTrue(environment.isSimulation)
        let session = InstallerSession(environment: environment)
        await session.inspect()
        switch scenario {
        case .unsupported, .engineUnavailable:
          guard case .unsupported(let failure) = session.phase else {
            return XCTFail(scenario.title)
          }
          if scenario == .unsupported {
            XCTAssertTrue(failure.isBlockedModel)
            XCTAssertTrue(
              failure.plainDetail.contains(
                "MacBook Pro 14-inch (M4 Pro, 2024) · Mac16,8 · apple,j614s"))
            let remedy = try XCTUnwrap(failure.remedy)
            XCTAssertTrue(remedy.contains("(34 models)"), remedy)
            XCTAssertTrue(remedy.contains("M3: iMac, MacBook Air, MacBook Pro"), remedy)
          }
          XCTAssertFalse(session.canStartInstallation)
          continue
        case .existingInstall:
          guard case .existingInstallRefused = session.phase else { return XCTFail(scenario.title) }
          continue
        default: break
        }
        await session.continueToPlan()
        switch scenario {
        case .downloadFailure, .invalidDownload, .outdatedInstaller, .planFailure,
          .insufficientSpace, .lowReserve,
          .noMacRelease, .modelNotOnChannel, .channelUnreachable:
          guard case .failed = session.phase else { return XCTFail(scenario.title) }
          XCTAssertFalse(session.hasExecutionStarted)
          XCTAssertTrue(session.canInspect)
          continue
        default: break
        }
        session.continueToPlanReview()
        if scenario == .allocationClamped {
          session.setAcknowledged(true)
          await session.replan(omarchyBytes: 650_000_000_000)
          guard case .planReview(let plan, let acknowledged) = session.phase else {
            return XCTFail(scenario.title)
          }
          XCTAssertEqual(plan.omarchyBytes, 137_438_953_472)
          XCTAssertEqual(plan.maximumBytes, plan.omarchyBytes)
          XCTAssertFalse(acknowledged)
          XCTAssertEqual(session.planRevision, 2)
          XCTAssertNotNil(session.allocationNotice)
        }
        session.setAcknowledged(true)
        session.approve()
        if scenario == .approvalChanged {
          guard case .failed = session.phase else { return XCTFail(scenario.title) }
          XCTAssertFalse(environment.hasApprovedPlan)
          continue
        }
        if scenario == .missingHelper {
          XCTAssertFalse(session.canStartInstallation)
          XCTAssertTrue(session.canEditPlan)
          continue
        }
        session.presentInstallCredentials()
        let dummy = try MachineOwnerAuthorization(
          username: "simulation", password: Data("simulation-only".utf8))
        await session.submit(dummy)
        if scenario == .credentialsRejected {
          XCTAssertEqual(session.credentialSheet.context?.error, .credentialsRejected)
          XCTAssertFalse(session.hasExecutionStarted)
          await session.submit(dummy)
        }
        if scenario == .spaceChanged {
          guard case .failed(let failure) = session.phase else { return XCTFail(scenario.title) }
          XCTAssertTrue(failure.replanAvailable)
          XCTAssertTrue(failure.plainDetail.contains("No disk changes were made."))
          XCTAssertFalse(session.hasExecutionStarted)
          XCTAssertTrue(session.canInspect)
          await session.replanAfterEngineRefusal()
          guard case .planReview(let plan, let acknowledged) = session.phase else {
            return XCTFail(scenario.title)
          }
          XCTAssertEqual(plan.omarchyBytes, 133_000_000_000)
          XCTAssertFalse(acknowledged)
          XCTAssertFalse(environment.hasApprovedPlan)
          XCTAssertEqual(
            session.allocationNotice,
            "Space for Omarchy changed from 137 GB to 133 GB. Review the updated size before installing."
          )
          session.setAcknowledged(true)
          session.approve()
          session.presentInstallCredentials()
          await session.submit(dummy)
        }
        if scenario == .recoveryRetry {
          XCTAssertTrue(session.canRetryRecoveryAuthorization)
          XCTAssertFalse(session.canInspect)
          session.presentRecoveryRetryCredentials()
          await session.submit(dummy)
        }
        switch scenario {
        case .connectionLost, .emptyReply, .helperFailure, .manualRecovery, .preparedResumeMismatch:
          guard case .failed(let failure) = session.phase else { return XCTFail(scenario.title) }
          XCTAssertFalse(failure.plainDetail.contains("Nothing was changed"))
          XCTAssertFalse(session.canInspect)
          XCTAssertFalse(session.canRetryRecoveryAuthorization)
          if scenario != .manualRecovery { XCTAssertEqual(session.journal.checkpoints.count, 1) }
          if scenario == .preparedResumeMismatch {
            XCTAssertTrue(failure.headline.contains("saved checkpoint"))
            XCTAssertTrue(failure.plainDetail.contains("already prepared disk space"))
            XCTAssertTrue(try XCTUnwrap(failure.remedy).contains("do not delete the journal"))
            XCTAssertFalse(failure.replanAvailable)
          }
        case .completed:
          guard case .done = session.phase else { return XCTFail(scenario.title) }
        default:
          guard case .awaitingRecovery = session.phase else { return XCTFail(scenario.title) }
          if scenario == .success { XCTAssertEqual(session.journal.checkpoints.count, 3) }
          XCTAssertEqual(session.shutDown(), scenario != .shutdownFailure)
          XCTAssertTrue(
            try XCTUnwrap(session.shutdownMessage).contains(
              scenario == .shutdownFailure ? "Simulated shutdown failed" : "Simulation complete"))
        }
      }
    }

    func testFreeExtentCanGrowWithoutChangingMacOSOrTotalCapacity() async throws {
      let environment = InstallerSimulationEnvironment(scenario: .freeSpace, delay: .zero)
      let first = try await environment.preparePlan(omarchyBytes: nil, progress: { _ in })
      let next = try await environment.preparePlan(
        omarchyBytes: 600_000_000_000, progress: { _ in })
      guard case .plan(let initial) = first, case .plan(let larger) = next else {
        return XCTFail("Expected plans")
      }
      XCTAssertEqual(initial.diskTotalBytes, larger.diskTotalBytes)
      XCTAssertEqual(larger.omarchyBytes, 600_000_000_000)
      XCTAssertEqual(larger.macOSBytes(for: larger.omarchyBytes), 100_000_000_000)
      XCTAssertEqual(larger.unallocatedBytes(for: larger.omarchyBytes), 200_000_000_000)
      XCTAssertGreaterThan(larger.maximumBytes, initial.omarchyBytes + 100_000_000_000)
    }

    func testCancelledSimulationCannotPrepareOrExecute() async throws {
      let environment = InstallerSimulationEnvironment(scenario: .success, delay: .zero)
      environment.cancel()
      do {
        _ = try await environment.inspect()
        XCTFail("Cancelled simulation should stop")
      } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRecoveryRetryDoesNotReplayDiskWork() async throws {
      let environment = InstallerSimulationEnvironment(scenario: .recoveryRetry, delay: .zero)
      try environment.approve()
      let result = try await environment.execute(
        operation: .retryRecoveryAuthorization,
        authorization: MachineOwnerAuthorization(
          username: "simulation", password: Data("dummy".utf8)),
        encryptLinuxDisk: true,
        journal: { _ in XCTFail("Recovery retry must not simulate another disk write") })
      XCTAssertEqual(result.nextAction, .enterRecovery)
    }
  }
#endif
