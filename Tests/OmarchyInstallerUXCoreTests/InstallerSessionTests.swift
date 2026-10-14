#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import RecoveryAccountCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  @MainActor
  final class InstallerSessionTests: XCTestCase {
    func testRecoveryHandoffCanShutDownBeforeCreatingAccount() async throws {
      let environment = MockInstallerEnvironment()
      environment.shutdownAccepted = true
      environment.host = HostDisplay(
        chipAndSpace: "Apple A18 Pro", supported: true,
        existingInstalls: [
          ExistingInstallDisplay(sourceIdentifier: "disk0s3", sizeDescription: "89 GB")
        ])
      let target = RecoveryAccountTarget(
        volumeName: "Omarchy", systemUUID: "11111111-1111-4111-8111-111111111111",
        dataUUID: "22222222-2222-4222-8222-222222222222",
        groupUUID: "33333333-3333-4333-8333-333333333333",
        prebootUUID: "44444444-4444-4444-8444-444444444444")
      for phase in [nil, "allocating", "creating", "prepared", "awaiting-ownership", "finalized"]
        as [String?]
      {
        environment.accountReply = RecoveryAccountReply(
          ticket: "bound-ticket", target: target,
          record: phase.map {
            RecoveryAccountRecord(
              target: target, username: "owner", generatedUID: UUID().uuidString, phase: $0)
          })
        let session = InstallerSession(environment: environment)
        await session.inspect()
        let before = environment.requestShutdownCount
        let accepted = try await session.prepareRecoveryHandoffAndShutdown()
        XCTAssertTrue(accepted)
        XCTAssertEqual(environment.requestShutdownCount, before + 1)
      }
    }
    func testRecoveryHandoffFailureDoesNotShutDown() async throws {
      let environment = MockInstallerEnvironment()
      environment.host = HostDisplay(
        chipAndSpace: "Apple A18 Pro", supported: true,
        existingInstalls: [
          ExistingInstallDisplay(sourceIdentifier: "disk0s3", sizeDescription: "89 GB")
        ])
      let target = RecoveryAccountTarget(
        volumeName: "Omarchy", systemUUID: "11111111-1111-4111-8111-111111111111",
        dataUUID: "22222222-2222-4222-8222-222222222222",
        groupUUID: "33333333-3333-4333-8333-333333333333",
        prebootUUID: "44444444-4444-4444-8444-444444444444")
      environment.accountReply = RecoveryAccountReply(ticket: "bound-ticket", target: target)
      for changedTarget in [false, true] {
        environment.handoffFails = !changedTarget
        environment.handoffOverride = changedTarget ? RecoveryAccountReply() : nil
        let session = InstallerSession(environment: environment)
        await session.inspect()
        do {
          _ = try await session.prepareRecoveryHandoffAndShutdown()
          XCTFail("Incomplete or changed Recovery handoff must fail")
        } catch {}
        XCTAssertEqual(environment.requestShutdownCount, 0)
        XCTAssertFalse(session.isBusy)
      }
    }

    func testCompletedInstallResumesOnlyAccountSetupWithoutExecutingAgain() async throws {
      let environment = MockInstallerEnvironment()
      environment.host = HostDisplay(
        chipAndSpace: "Apple A18 Pro", supported: true,
        existingInstalls: [
          ExistingInstallDisplay(sourceIdentifier: "disk0s3", sizeDescription: "89 GB")
        ])
      let target = RecoveryAccountTarget(
        volumeName: "Omarchy",
        systemUUID: "11111111-1111-4111-8111-111111111111",
        dataUUID: "22222222-2222-4222-8222-222222222222",
        groupUUID: "33333333-3333-4333-8333-333333333333",
        prebootUUID: "44444444-4444-4444-8444-444444444444")
      environment.accountReply = RecoveryAccountReply(ticket: "bound-ticket", target: target)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      XCTAssertEqual(session.recoveryAccount?.target, target)
      XCTAssertFalse(session.canChangeChannel)
      try await session.prepareRecoveryAccount(username: "owner", password: Data("short".utf8))
      XCTAssertEqual(environment.accountCalls, ["inspect", "prepare:bound-ticket:owner"])
      XCTAssertEqual(environment.executeCount, 0)
      XCTAssertEqual(environment.prepareCount, 0)
      XCTAssertEqual(environment.prefetchStartCount, 0)
    }
    func testChannelAvailabilityKeepsTheLatestCheck() async {
      let environment = MockInstallerEnvironment()
      let slow = OperationGate()
      environment.availabilityGates = [slow, nil]
      let unreachable = ReleaseChannelAvailability.checkFailed(.network)
      let current: [ReleaseChannel: ReleaseChannelAvailability] = [
        .stable: .noRelease, .rc: .noRelease, .edge: .available,
      ]
      environment.availabilityAnswers = [
        [.stable: unreachable, .rc: unreachable, .edge: unreachable],
        current,
      ]
      let session = InstallerSession(environment: environment)
      XCTAssertEqual(session.channelAvailability, [:])

      let first = Task { await session.refreshChannelAvailability() }
      await slow.waitUntilEntered()
      await session.refreshChannelAvailability()
      XCTAssertEqual(session.channelAvailability[.edge], .available)

      await slow.release()
      await first.value
      // The slow, older check finished last but does not overwrite the newer one.
      XCTAssertEqual(session.channelAvailability, current)
    }

    func testPrivateLimineProfileSubmitsExplicitEncryptionChoice() async throws {
      for encrypt in [false, true] {
        let environment = MockInstallerEnvironment()
        let profile = InstallerBuildProfile.resolve(infoDictionary: [
          "OmarchyPrivateLimineTest": true
        ])
        let session = InstallerSession(
          environment: environment, allowsEncryption: profile.allowsEncryption)
        XCTAssertTrue(session.encryptLinuxDisk)
        await session.inspect()
        await session.continueToPlan()
        session.continueToPlanReview()
        session.setEncryptLinuxDisk(encrypt)
        XCTAssertEqual(environment.storedEncryptLinuxDisk, encrypt)
        session.setAcknowledged(true)
        session.approve()
        session.presentInstallCredentials()
        await session.submit(try authorization())
        XCTAssertEqual(environment.lastEncryptLinuxDisk, encrypt)
      }
    }

    func testPlainOnlyProfileCannotEnableEncryptionOrResetIntoIt() async throws {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment, allowsEncryption: false)
      XCTAssertFalse(session.encryptLinuxDisk)
      XCTAssertFalse(environment.storedEncryptLinuxDisk)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setEncryptLinuxDisk(true)
      XCTAssertFalse(session.encryptLinuxDisk)
      XCTAssertFalse(environment.storedEncryptLinuxDisk)
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      await session.submit(try authorization())
      XCTAssertEqual(environment.lastEncryptLinuxDisk, false)
    }

    func testPlainOnlyProfileReinspectKeepsPlainState() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment, allowsEncryption: false)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setEncryptLinuxDisk(true)
      await session.inspect()
      XCTAssertFalse(session.encryptLinuxDisk)
      XCTAssertFalse(environment.storedEncryptLinuxDisk)
    }

    func testMissingLiveInstallationCannotReachShutdownAfterCompletion() async throws {
      let environment = MockInstallerEnvironment()
      environment.accountReply = nil
      let session = await ready(environment)
      session.presentInstallCredentials()
      await session.submit(try authorization())
      guard case .failed(let failure) = session.phase else {
        return XCTFail("A historical completion must not show the Recovery handoff")
      }
      XCTAssertEqual(failure.headline, "Installation could not be verified")
      XCTAssertFalse(session.shutDown())
      XCTAssertEqual(environment.requestShutdownCount, 0)
    }

    func testHappyPathFollowsTheTransitionTable() async throws {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)

      await session.inspect()
      guard case .welcome = session.phase else {
        return XCTFail("Expected welcome, got \(session.phase)")
      }

      await session.continueToPlan()
      session.continueToPlanReview()
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected planReview, got \(session.phase)")
      }
      XCTAssertFalse(acknowledged)

      session.setAcknowledged(true)
      session.approve()
      guard case .awaitingInstall = session.phase else {
        return XCTFail("Expected awaitingInstall, got \(session.phase)")
      }
      XCTAssertEqual(environment.approveCount, 1)
      XCTAssertTrue(session.canStartInstallation)

      session.presentInstallCredentials()
      XCTAssertNotNil(session.credentialSheet.context)

      await session.submit(try authorization())
      guard case .awaitingRecovery = session.phase else {
        return XCTFail("Expected awaitingRecovery, got \(session.phase)")
      }
      XCTAssertTrue(session.hasExecutionStarted)
      XCTAssertEqual(environment.executeCount, 1)
      XCTAssertEqual(environment.lastOperation, .install)
      XCTAssertNil(session.credentialSheet.context)

      session.shutDown()
      XCTAssertEqual(environment.requestShutdownCount, 1)
      guard case .awaitingRecovery = session.phase else {
        return XCTFail("Expected awaitingRecovery, got \(session.phase)")
      }
    }

    func testBlockedHostLocksToUnsupported() async {
      let environment = MockInstallerEnvironment()
      environment.installationBlocked = true
      environment.host = MockInstallerEnvironment.blockedHost
      let session = InstallerSession(environment: environment)

      await session.inspect()

      guard case .unsupported(let failure) = session.phase else {
        return XCTFail("Expected unsupported, got \(session.phase)")
      }
      XCTAssertTrue(failure.isBlockedModel)
      XCTAssertTrue(session.installationBlocked)
      XCTAssertFalse(session.canStartInstallation)

      // Locked: nothing but re-inspection moves the phase.
      await session.continueToPlan()
      session.continueToPlanReview()
      guard case .unsupported = session.phase else {
        return XCTFail("Blocked host must stay locked")
      }
    }

    func testUnsupportedEngineExplainsItselfWithoutClaimingABlockedModel() async {
      let environment = MockInstallerEnvironment()
      environment.host = HostDisplay(
        chipAndSpace: "Apple M1 Pro · 464 GB free",
        supported: false,
        blockingReason: PlainLanguage.engineUnavailable
      )
      let session = InstallerSession(environment: environment)

      await session.inspect()

      guard case .unsupported(let failure) = session.phase else {
        return XCTFail("Expected unsupported, got \(session.phase)")
      }
      XCTAssertFalse(failure.isBlockedModel)
      XCTAssertEqual(failure.headline, PlainLanguage.notReadyHeadline)
      XCTAssertEqual(failure.plainDetail, PlainLanguage.engineUnavailable)
    }

    func testSpaceShortfallStopsBeforeAnythingIsDownloaded() async {
      let environment = MockInstallerEnvironment()
      environment.host = HostDisplay(
        chipAndSpace: "Apple M1 · 117 GB free",
        supported: true,
        spaceShortfall: .insufficientSpace(
          requiredBytes: 76_562_825_216, availableBytes: 73_528_246_272)
      )
      let session = InstallerSession(environment: environment)

      await session.inspect()

      guard case .unsupported(let failure) = session.phase else {
        return XCTFail("Expected unsupported, got \(session.phase)")
      }
      XCTAssertFalse(failure.isBlockedModel)
      XCTAssertEqual(failure.device, environment.host)
      XCTAssertEqual(
        failure.headline, "Free up at least 4 GB to install Omarchy")
      XCTAssertEqual(
        failure.remedy,
        "Remove files you no longer need in macOS and empty the Trash, then choose Check again. The installer will check the available space again before allowing installation."
      )

      await session.continueToPlan()
      XCTAssertEqual(environment.prepareCount, 0)
    }

    func testPreparationHoldsUntilContinue() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()

      guard case .planPrepared(_, let update) = session.phase else {
        return XCTFail("Expected planPrepared, got \(session.phase)")
      }
      XCTAssertTrue(update.rows.allSatisfy { $0.phase == .verified })
      session.approve()
      XCTAssertEqual(environment.approveCount, 0)

      session.continueToPlanReview()
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected planReview, got \(session.phase)")
      }
      XCTAssertFalse(acknowledged)
    }

    func testReplanCarriesTheChosenSizeAndSkipsTheHold() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()

      await session.replan(omarchyBytes: 200_000_000_000)

      XCTAssertEqual(environment.lastOmarchyBytes, 200_000_000_000)
      XCTAssertEqual(environment.prepareCount, 2)
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected planReview after replan, got \(session.phase)")
      }
      XCTAssertFalse(acknowledged)
    }

    func testReplanRequiresFreshAcknowledgementEvenWhenAllocationIsUnchanged() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)

      await session.replan(omarchyBytes: 200_000_000_000)

      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected planReview after replan, got \(session.phase)")
      }
      XCTAssertFalse(acknowledged)
      XCTAssertEqual(session.planRevision, 2)
      XCTAssertNotNil(session.allocationNotice)
      session.approve()
      XCTAssertEqual(environment.approveCount, 0)
    }

    func testReplanKeepsTheRunningDownload() async throws {
      let environment = MockInstallerEnvironment()
      environment.payloadPrefetchRequired = true
      let gate = OperationGate()
      environment.prefetchGate = gate
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      await gate.waitUntilEntered()
      session.continueToPlanReview()
      let cancelsBefore = environment.prefetchCancelCount

      await session.replan(omarchyBytes: 200_000_000_000)

      XCTAssertEqual(environment.prefetchCancelCount, cancelsBefore)
      await waitUntil { environment.prefetchStartCount == 2 }
      XCTAssertNotEqual(session.prefetchState, .verified)
      session.setAcknowledged(true)
      session.approve()
      XCTAssertFalse(session.canStartInstallation)

      await gate.release()
      await waitUntil { session.prefetchState == .verified }
      XCTAssertTrue(session.canStartInstallation)
    }

    func testAFirstPreparationThatFailsStopsTheDownloadItStarted() async {
      let environment = MockInstallerEnvironment()
      environment.payloadPrefetchRequired = true
      environment.prepareError = InstallerReleaseConfigurationError.releaseResourcesUnavailable
      let session = InstallerSession(environment: environment)
      await session.inspect()

      await session.continueToPlan()

      guard case .failed = session.phase else {
        return XCTFail("Expected failed, got \(session.phase)")
      }
      XCTAssertGreaterThan(environment.prefetchCancelCount, environment.cancelsBeforePrepare)
      XCTAssertEqual(environment.prefetchStartCount, 0)
    }

    func testAnExistingInstallFoundWhilePlanningStopsTheDownload() async {
      let environment = MockInstallerEnvironment()
      environment.payloadPrefetchRequired = true
      environment.existingInstalls = [
        ExistingInstallDisplay(sourceIdentifier: "disk0s3", sizeDescription: "128 GB")
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()

      await session.continueToPlan()

      guard case .existingInstallRefused = session.phase else {
        return XCTFail("Expected existingInstallRefused, got \(session.phase)")
      }
      XCTAssertGreaterThan(environment.prefetchCancelCount, environment.cancelsBeforePrepare)
    }

    func testAFailedSizeChangeStopsTheDownload() async {
      let environment = MockInstallerEnvironment()
      environment.payloadPrefetchRequired = true
      let gate = OperationGate()
      environment.prefetchGate = gate
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      await gate.waitUntilEntered()
      session.continueToPlanReview()
      let cancelsBefore = environment.prefetchCancelCount
      environment.prepareError = InstallerReleaseConfigurationError.releaseResourcesUnavailable

      await session.replan(omarchyBytes: 200_000_000_000)

      guard case .failed = session.phase else {
        return XCTFail("Expected failed, got \(session.phase)")
      }
      XCTAssertGreaterThan(environment.prefetchCancelCount, cancelsBefore)
      await gate.release()
    }

    func testReplanWaitsForAPayloadTheCatalogReplaced() async throws {
      let environment = MockInstallerEnvironment()
      environment.payloadPrefetchRequired = true
      let first = OperationGate()
      environment.prefetchGate = first
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      await first.waitUntilEntered()
      await first.release()
      await waitUntil { session.prefetchState == .verified }

      session.continueToPlanReview()
      let second = OperationGate()
      environment.prefetchGate = second
      environment.payloadPrefetchState = .idle
      await session.replan(omarchyBytes: 200_000_000_000)

      await second.waitUntilEntered()
      XCTAssertNotEqual(session.prefetchState, .verified)
      XCTAssertEqual(environment.prefetchStartCount, 2)
      session.setAcknowledged(true)
      session.approve()
      XCTAssertFalse(session.canStartInstallation)

      await second.release()
      await waitUntil { session.prefetchState == .verified }
      XCTAssertTrue(session.canStartInstallation)
    }

    func testTheOldDownloadCannotVerifyAPayloadTheCatalogReplaced() async throws {
      let environment = MockInstallerEnvironment()
      environment.payloadPrefetchRequired = true
      let first = OperationGate()
      environment.prefetchGate = first
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      await first.waitUntilEntered()
      session.continueToPlanReview()

      let second = OperationGate()
      environment.prefetchGate = second
      environment.payloadPrefetchState = .idle
      await session.replan(omarchyBytes: 200_000_000_000)
      await second.waitUntilEntered()

      await first.release()
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertNotEqual(session.prefetchState, .verified)
      session.setAcknowledged(true)
      session.approve()
      XCTAssertFalse(session.canStartInstallation)

      await second.release()
      await waitUntil { session.prefetchState == .verified }
      XCTAssertTrue(session.canStartInstallation)
    }

    func testAFailureDeliveredAfterAReplanCannotBlockTheRetry() async throws {
      let environment = MockInstallerEnvironment()
      environment.payloadPrefetchRequired = true
      let first = OperationGate()
      environment.prefetchGate = first
      environment.prefetchFailure = true
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      await first.waitUntilEntered()
      session.continueToPlanReview()

      let second = OperationGate()
      environment.prefetchGate = second
      environment.prefetchFailure = false
      await session.replan(omarchyBytes: 200_000_000_000)
      await second.waitUntilEntered()

      await first.release()
      try await Task.sleep(for: .milliseconds(50))
      if case .failed = session.prefetchState {
        XCTFail("A stale failure reached the session: \(session.prefetchState)")
      }

      await second.release()
      await waitUntil { session.prefetchState == .verified }
      session.setAcknowledged(true)
      session.approve()
      XCTAssertTrue(session.canStartInstallation)
    }

    func testAFailedDownloadShowsItsReasonAndCanBeRetried() async throws {
      let environment = MockInstallerEnvironment()
      environment.payloadPrefetchRequired = true
      environment.prefetchFailure = true
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      await waitUntil {
        if case .failed = session.prefetchState { return true }
        return false
      }
      XCTAssertEqual(session.prefetchState, .failed("retry"))
      XCTAssertTrue(session.canRetryPrefetch)

      environment.prefetchFailure = false
      session.retryPrefetch()
      XCTAssertEqual(environment.prefetchRestartCount, 1)
      await waitUntil { session.prefetchState == .verified }
      XCTAssertFalse(session.canRetryPrefetch)
      session.setAcknowledged(true)
      session.approve()
      XCTAssertTrue(session.canStartInstallation)
    }

    func testApproveRequiresAcknowledgement() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()

      session.approve()

      XCTAssertEqual(environment.approveCount, 0)
      guard case .planReview = session.phase else {
        return XCTFail("Expected to stay in planReview")
      }
    }

    func testIllegalTransitionsAreNoOps() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)

      // Before inspection completes nothing may advance.
      session.approve()
      session.setAcknowledged(true)
      session.presentInstallCredentials()
      session.refreshHelperStatus()
      await session.continueToPlan()
      session.continueToPlanReview()

      XCTAssertEqual(environment.approveCount, 0)
      XCTAssertEqual(environment.prepareCount, 0)
      guard case .inspecting = session.phase else {
        return XCTFail("Expected inspecting, got \(session.phase)")
      }
    }

    func testCredentialRejectionReopensTheSheet() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.machineOwnerCredentialsRejected),
        .success(MockInstallerEnvironment.recoveryCompletion),
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()

      await session.submit(try authorization())

      guard case .awaitingInstall(_, _, let sheet) = session.phase else {
        return XCTFail("Expected awaitingInstall, got \(session.phase)")
      }
      XCTAssertEqual(sheet.context?.error, .credentialsRejected)
      // The helper rejects credentials before any work starts, so the one-shot
      // latch is released for a second attempt.
      XCTAssertFalse(session.hasExecutionStarted)
      XCTAssertTrue(session.canStartInstallation)

      await session.submit(try authorization())
      guard case .awaitingRecovery = session.phase else {
        return XCTFail("Expected awaitingRecovery, got \(session.phase)")
      }
      XCTAssertEqual(environment.executeCount, 2)
    }

    func testNonCredentialFailureKeepsTheOneShotLatch() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.connectionFailed)
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()

      await session.submit(try authorization())

      guard case .failed(let failure) = session.phase else {
        return XCTFail("Expected failed, got \(session.phase)")
      }
      XCTAssertFalse(failure.retryRecoveryAvailable)
      XCTAssertTrue(session.hasExecutionStarted)
      XCTAssertNotNil(failure.technicalDetail)
    }

    func testRecoveryRetryIsOnlyReachableWhenEligible() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.recoveryAuthorizationFailed),
        .success(MockInstallerEnvironment.recoveryCompletion),
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      await session.submit(try authorization())

      guard case .failed(let failure) = session.phase else {
        return XCTFail("Expected failed, got \(session.phase)")
      }
      XCTAssertTrue(failure.retryRecoveryAvailable)
      XCTAssertTrue(session.canRetryRecoveryAuthorization)

      session.presentRecoveryRetryCredentials()
      XCTAssertEqual(
        session.credentialSheet.context?.kind,
        .retryRecoveryAuthorization
      )

      await session.submit(try authorization())
      XCTAssertEqual(environment.lastOperation, .retryRecoveryAuthorization)
      guard case .awaitingRecovery = session.phase else {
        return XCTFail("Expected awaitingRecovery, got \(session.phase)")
      }
    }

    func testRetrySheetStaysClosedWithoutEligibility() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.connectionFailed)
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      await session.submit(try authorization())

      session.presentRecoveryRetryCredentials()

      XCTAssertNil(session.credentialSheet.context)
      XCTAssertFalse(session.canRetryRecoveryAuthorization)
    }

    func testHelperMustBeReachableBeforeInstallationCanStart() async {
      let environment = MockInstallerEnvironment()
      environment.helper = HelperDisplay(status: .missing)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()

      XCTAssertFalse(session.canStartInstallation)
      session.presentInstallCredentials()
      XCTAssertNil(session.credentialSheet.context)

      // The installer package installs the system daemon; refreshing picks it
      // up. There is no registration or Login Items approval step.
      environment.helper = HelperDisplay(status: .current)
      session.refreshHelperStatus()
      XCTAssertTrue(session.canStartInstallation)
    }

    func testAMissingHelperTheBuildCanInstallDoesNotBlockInstallation() async throws {
      let environment = MockInstallerEnvironment()
      environment.helper = HelperDisplay(status: .missing, canInstall: true)
      let session = try await approvedSession(environment)

      XCTAssertTrue(session.canStartInstallation)
      session.presentInstallCredentials()
      XCTAssertEqual(session.credentialSheet.context?.mentionsBackgroundItem, true)

      await session.submit(try authorization())
      XCTAssertEqual(environment.calls, ["ensureHelper:owner", "execute"])
    }

    func testACurrentHelperNeedsNoBackgroundItemNotice() async throws {
      let environment = MockInstallerEnvironment()
      environment.helper = HelperDisplay(status: .current, canInstall: true)
      let session = try await approvedSession(environment)

      session.presentInstallCredentials()
      XCTAssertEqual(session.credentialSheet.context?.mentionsBackgroundItem, false)
      await session.submit(try authorization())
      // Setup still runs: it confirms the helper answers and is current.
      XCTAssertEqual(environment.calls, ["ensureHelper:owner", "execute"])
    }

    func testATypoDuringHelperSetupShowsTheUsualRejection() async throws {
      let environment = MockInstallerEnvironment()
      environment.helper = HelperDisplay(status: .missing, canInstall: true)
      environment.ensureHelperError = EngineXPCSubmissionError.machineOwnerCredentialsRejected
      let session = try await approvedSession(environment)
      session.presentInstallCredentials()

      await session.submit(try authorization())

      XCTAssertEqual(session.credentialSheet.context?.error, .credentialsRejected)
      XCTAssertEqual(session.credentialSheet.context?.mentionsBackgroundItem, true)
      XCTAssertEqual(environment.executeCount, 0)
      XCTAssertTrue(session.canStartInstallation)
    }

    func testHelperSetupFailuresReopenTheSheetWithoutRunning() async throws {
      let cases: [(InstallerHelperSetupError, CredentialSheetError)] = [
        (.cancelled, .helperSetupCancelled),
        (.switchedOff, .helperSwitchedOff),
        (.busy, .helperBusy),
        (.notAdministrator, .notAdministrator),
        (.failed("launchd"), .helperSetupFailed),
        (.unavailable, .helperSetupFailed),
      ]
      for (setupError, sheetError) in cases {
        let environment = MockInstallerEnvironment()
        environment.helper = HelperDisplay(status: .missing, canInstall: true)
        environment.ensureHelperError = setupError
        let session = try await approvedSession(environment)
        session.presentInstallCredentials()

        await session.submit(try authorization())

        XCTAssertEqual(session.credentialSheet.context?.error, sheetError, "\(setupError)")
        XCTAssertEqual(environment.executeCount, 0, "\(setupError)")
        // Nothing ran, so the person can simply try again.
        XCTAssertTrue(session.canStartInstallation, "\(setupError)")
        await session.submit(try authorization())
        XCTAssertEqual(environment.executeCount, 1, "\(setupError)")
      }
    }

    func testRecoveryRetrySetsUpTheHelperOnceForItsOwnPassword() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.recoveryAuthorizationFailed),
        .success(MockInstallerEnvironment.recoveryCompletion),
      ]
      let session = try await approvedSession(environment)
      session.presentInstallCredentials()
      await session.submit(try authorization())
      session.presentRecoveryRetryCredentials()
      await session.submit(try authorization())

      XCTAssertEqual(
        environment.calls, ["ensureHelper:owner", "execute", "ensureHelper:owner", "execute"])
    }

    func testASwitchedOffHelperIsOfferedBackBeforeThePasswordIsTyped() async throws {
      let environment = MockInstallerEnvironment()
      environment.helper = HelperDisplay(status: .current, canInstall: true)
      environment.probedHelper = HelperDisplay(status: .disabled, canInstall: true)
      let session = try await approvedSession(environment)
      session.presentInstallCredentials()
      XCTAssertEqual(session.credentialSheet.context?.helperSwitchedOff, false)

      await session.checkWhetherHelperIsSwitchedOff()

      XCTAssertEqual(session.credentialSheet.context?.helperSwitchedOff, true)
      XCTAssertEqual(session.credentialSheet.context?.mentionsBackgroundItem, true)
      await session.submit(try authorization())
      XCTAssertEqual(environment.calls, ["ensureHelper:owner:reenable", "execute"])
    }

    func testAnAnsweringHelperLeavesTheSheetAlone() async throws {
      let environment = MockInstallerEnvironment()
      environment.helper = HelperDisplay(status: .current, canInstall: true)
      let session = try await approvedSession(environment)
      session.presentInstallCredentials()

      await session.checkWhetherHelperIsSwitchedOff()

      XCTAssertEqual(session.credentialSheet.context?.helperSwitchedOff, false)
      await session.submit(try authorization())
      XCTAssertEqual(environment.calls, ["ensureHelper:owner", "execute"])
    }

    func testABuildThatCannotInstallTheHelperDoesNotOfferToTurnItOn() async throws {
      let environment = MockInstallerEnvironment()
      environment.probedHelper = HelperDisplay(status: .disabled, canInstall: false)
      let session = try await approvedSession(environment)
      session.presentInstallCredentials()

      await session.checkWhetherHelperIsSwitchedOff()

      XCTAssertEqual(session.credentialSheet.context?.helperSwitchedOff, false)
    }

    func testSwitchedOffFoundAtSubmitReopensTheSheetOfferingToTurnItOn() async throws {
      let environment = MockInstallerEnvironment()
      environment.helper = HelperDisplay(status: .current, canInstall: true)
      environment.ensureHelperError = InstallerHelperSetupError.switchedOff
      let session = try await approvedSession(environment)
      session.presentInstallCredentials()

      await session.submit(try authorization())

      XCTAssertEqual(session.credentialSheet.context?.error, .helperSwitchedOff)
      XCTAssertEqual(session.credentialSheet.context?.helperSwitchedOff, true)
      await session.submit(try authorization())
      XCTAssertEqual(
        environment.calls, ["ensureHelper:owner", "ensureHelper:owner:reenable", "execute"])
    }

    func testTheRecoveryRetrySheetIsOfferedTheSameChoice() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.recoveryAuthorizationFailed),
        .success(MockInstallerEnvironment.recoveryCompletion),
      ]
      let session = try await approvedSession(environment)
      session.presentInstallCredentials()
      await session.submit(try authorization())
      environment.helper = HelperDisplay(status: .current, canInstall: true)
      environment.probedHelper = HelperDisplay(status: .disabled, canInstall: true)
      session.presentRecoveryRetryCredentials()

      await session.checkWhetherHelperIsSwitchedOff()

      XCTAssertEqual(session.credentialSheet.context?.kind, .retryRecoveryAuthorization)
      XCTAssertEqual(session.credentialSheet.context?.helperSwitchedOff, true)
    }

    func testAnUnsupportedMacNeverReachesHelperSetup() async throws {
      let environment = MockInstallerEnvironment()
      environment.helper = HelperDisplay(status: .missing, canInstall: true)
      let session = try await approvedSession(environment)
      environment.installationBlocked = true

      XCTAssertFalse(session.canStartInstallation)
      session.presentInstallCredentials()
      XCTAssertNil(session.credentialSheet.context)
      await session.submit(try authorization())
      XCTAssertEqual(environment.calls, [])
    }

    func testABuildThatCannotInstallTheHelperStillNeedsItInPlace() async throws {
      let environment = MockInstallerEnvironment()
      environment.helper = HelperDisplay(status: .missing, canInstall: false)
      let session = try await approvedSession(environment)

      XCTAssertFalse(session.canStartInstallation)
      XCTAssertFalse(environment.helper.isReady)
    }

    private func approvedSession(
      _ environment: MockInstallerEnvironment
    ) async throws -> InstallerSession {
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      return session
    }

    func testJournalChunksDriveTheInstallingDisplay() async throws {
      let environment = MockInstallerEnvironment()
      environment.journalChunks = try JournalFixture.lines()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()

      await session.submit(try authorization())

      XCTAssertEqual(
        session.journal.checkpoints.map(\.identifier),
        [
          "apfs-target-prepared", "stub-and-esp-installed",
          "recovery-handoff-prepared",
        ]
      )
      XCTAssertFalse(session.journal.degraded)
    }

    func testDownloadProgressIsKeyedByRole() async {
      let environment = MockInstallerEnvironment()
      environment.progressUpdates = [
        AssetProgressUpdate(
          stage: .downloading,
          rows: [
            AssetProgressRow(
              role: "payload",
              fileName: "payload.zip",
              bytesCompleted: 10,
              totalBytes: 100,
              phase: .downloading
            )
          ]
        ),
        AssetProgressUpdate(
          stage: .downloading,
          rows: [
            AssetProgressRow(
              role: "payload",
              fileName: "payload.zip",
              bytesCompleted: 100,
              totalBytes: 100,
              phase: .verified
            ),
            AssetProgressRow(
              role: "engine",
              fileName: "engine.tar.gz",
              bytesCompleted: 5,
              totalBytes: 20,
              phase: .downloading
            ),
          ]
        ),
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()

      XCTAssertEqual(session.stagingProgress["payload"]?.phase, .verified)
      XCTAssertEqual(session.stagingProgress["payload"]?.bytesCompleted, 100)
      XCTAssertEqual(session.stagingProgress["engine"]?.bytesCompleted, 5)
    }

    func testReInspectionCannotClearAnExecutionLatch() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [.failure(EngineXPCSubmissionError.recoveryAuthorizationFailed)]
      let session = await ready(environment)
      session.presentInstallCredentials()
      await session.submit(try authorization())
      let phase = session.phase
      let discards = environment.discardCount
      await session.inspect()
      XCTAssertEqual(session.phase, phase)
      XCTAssertEqual(environment.discardCount, discards)
      XCTAssertTrue(session.hasExecutionStarted)
      XCTAssertTrue(session.recoveryRetryAvailable)
      XCTAssertFalse(session.canChangeChannel)
    }

    func testCancellationAllowsEditingButRevokesApproval() async {
      let environment = MockInstallerEnvironment()
      let session = await ready(environment)
      session.presentInstallCredentials()
      session.dismissCredentials()
      XCTAssertTrue(session.canEditPlan)
      session.editPlan()
      XCTAssertFalse(environment.hasApprovedPlan)
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected review")
      }
      XCTAssertFalse(acknowledged)
      XCTAssertFalse(session.canStartInstallation)
    }

    func testInspectionCannotOverlapInspection() async {
      let environment = MockInstallerEnvironment()
      let gate = OperationGate()
      environment.inspectGate = gate
      let session = InstallerSession(environment: environment)
      let operation = Task { await session.inspect() }
      await gate.waitUntilEntered()
      let discards = environment.discardCount
      await session.inspect()
      XCTAssertEqual(environment.discardCount, discards)
      XCTAssertFalse(session.canChangeChannel)
      await gate.release()
      await operation.value
      guard case .welcome = session.phase else { return XCTFail("Expected welcome") }
    }

    func testPreparationBlocksResetAndRejectsDelayedProgress() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      let gate = OperationGate()
      environment.prepareGate = gate
      let operation = Task { await session.continueToPlan() }
      await gate.waitUntilEntered()
      let discards = environment.discardCount
      await session.inspect()
      XCTAssertEqual(environment.discardCount, discards)
      XCTAssertFalse(session.canChangeChannel)
      await gate.release()
      await operation.value
      session.continueToPlanReview()
      let phase = session.phase
      environment.savedProgress?(AssetProgressUpdate(stage: .downloading))
      await Task.yield()
      XCTAssertEqual(session.phase, phase)
    }

    func testExecutionBlocksResetBackAndDuplicateSubmission() async throws {
      let environment = MockInstallerEnvironment()
      let session = await ready(environment)
      let gate = OperationGate()
      environment.executeGate = gate
      session.presentInstallCredentials()
      let authorization = try authorization()
      let operation = Task { await session.submit(authorization) }
      await gate.waitUntilEntered()
      let phase = session.phase
      let discards = environment.discardCount
      await session.inspect()
      session.editPlan()
      session.dismissCredentials()
      await session.submit(authorization)
      XCTAssertEqual(session.phase, phase)
      XCTAssertEqual(environment.discardCount, discards)
      XCTAssertEqual(environment.executeCount, 1)
      XCTAssertTrue(session.hasExecutionStarted)
      XCTAssertFalse(session.canChangeChannel)
      await gate.release()
      await operation.value
      let terminal = session.phase
      environment.savedJournal?(try JournalFixture.data())
      await Task.yield()
      XCTAssertEqual(session.phase, terminal)
    }

    func testUnknownOutcomesStayLockedWithAndWithoutCheckpointEvidence() async throws {
      let errors: [any Error] = [
        EngineXPCSubmissionError.connectionFailed,
        EngineXPCSubmissionError.emptyResponse,
        EngineXPCSubmissionError.helperRejected(domain: "Executor", code: 1),
      ]
      for error in errors {
        for hasCheckpoint in [false, true] {
          let environment = MockInstallerEnvironment()
          environment.executeResults = [.failure(error)]
          if hasCheckpoint {
            environment.journalChunks = Array(try JournalFixture.lines().prefix(5))
          }
          let session = await ready(environment)
          session.presentInstallCredentials()
          await session.submit(try authorization())
          guard case .failed(let failure) = session.phase else {
            return XCTFail("Expected failure")
          }
          XCTAssertFalse(failure.plainDetail.contains("Nothing was changed"))
          XCTAssertFalse(session.canInspect)
          XCTAssertFalse(session.canRetryRecoveryAuthorization)
          XCTAssertEqual(session.journal.checkpoints.isEmpty, !hasCheckpoint)
        }
      }
    }

    func testEngineRefusalReleasesTheLatchOnlyWithJournalProof() async throws {
      for unchanged in [false, true] {
        let environment = MockInstallerEnvironment()
        environment.executeResults = [
          .failure(
            EngineXPCSubmissionError.engineFailed(
              EngineFailureNotice(
                reason: .approvedSpaceChanged, exitStatus: 1, diskUnchanged: unchanged,
                summary: "omarchy_execution.ExecutionAdmissionError: approved extent changed")))
        ]
        let session = await ready(environment)
        let approvedBytes = environment.plan.omarchyBytes
        session.presentInstallCredentials()
        await session.submit(try authorization())
        guard case .failed(let failure) = session.phase else {
          return XCTFail("Expected failure")
        }
        XCTAssertEqual(failure.replanAvailable, unchanged)
        XCTAssertEqual(session.hasExecutionStarted, !unchanged)
        XCTAssertEqual(session.canInspect, unchanged)
        let prepared = environment.prepareCount

        await session.replanAfterEngineRefusal()
        if unchanged {
          XCTAssertEqual(environment.prepareCount, prepared + 1)
          XCTAssertEqual(environment.lastOmarchyBytes, approvedBytes)
          guard case .planReview(_, let acknowledged) = session.phase else {
            return XCTFail("Expected planReview, got \(session.phase)")
          }
          XCTAssertFalse(acknowledged)
          XCTAssertFalse(session.canStartInstallation)
        } else {
          XCTAssertEqual(environment.prepareCount, prepared)
          guard case .failed = session.phase else { return XCTFail("Expected failure") }
        }
      }
    }

    func testUnsupportedModelHostNamesTheMac() async throws {
      let environment = MockInstallerEnvironment()
      environment.engineSupported = false
      environment.host = HostDisplay(
        chipAndSpace: "Apple M3 · 400 GB free", supported: false,
        unsupportedModel: UnsupportedModelDisplay(
          deviceIdentifier: "apple,j504", modelIdentifier: "Mac15,3",
          supportedDeviceIdentifiers: ["apple,j314s"]))
      let session = InstallerSession(environment: environment)
      await session.inspect()
      guard case .unsupported(let failure) = session.phase else {
        return XCTFail("Expected unsupported, got \(session.phase)")
      }
      XCTAssertTrue(failure.isBlockedModel)
      XCTAssertTrue(failure.plainDetail.contains("Mac15,3"))
      XCTAssertTrue(try XCTUnwrap(failure.remedy).contains("M1: MacBook Pro"))
      XCTAssertNotNil(failure.device)
    }

    func testShutdownRetainsInstructionsForAcceptedAndFailedRequests() async throws {
      for accepted in [false, true] {
        let environment = MockInstallerEnvironment()
        environment.shutdownAccepted = accepted
        let session = await ready(environment)
        XCTAssertFalse(session.shutDown())
        XCTAssertEqual(environment.requestShutdownCount, 0)
        session.presentInstallCredentials()
        await session.submit(try authorization())
        let phase = session.phase
        XCTAssertEqual(session.shutDown(), accepted)
        XCTAssertEqual(session.phase, phase)
        XCTAssertNotNil(session.shutdownMessage)
        XCTAssertEqual(environment.requestShutdownCount, 1)
      }
    }

    private func ready(_ environment: MockInstallerEnvironment) async -> InstallerSession {
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      return session
    }

    func testPreparationFailureSurfacesTechnicalDetail() async {
      let environment = MockInstallerEnvironment()
      environment.prepareError =
        InstallerReleaseConfigurationError
        .releaseResourcesUnavailable
      let session = InstallerSession(environment: environment)
      await session.inspect()

      await session.continueToPlan()
      session.continueToPlanReview()

      guard case .failed(let failure) = session.phase else {
        return XCTFail("Expected failed, got \(session.phase)")
      }
      XCTAssertEqual(failure.plainDetail, PlainLanguage.releaseResourcesUnavailable)
      XCTAssertNotNil(failure.technicalDetail)
    }

    func testSpaceShortfallRoundsUpAndRequiresAFreshPlanAfterRechecking() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      // A fractional GB must not be rounded down, including just above a whole GB.
      for (available, expectedGB): (UInt64, Int) in [
        (34_500_000_000, 6), (34_000_000_000, 6), (33_999_999_999, 7),
      ] {
        environment.prepareError = InstallerAllocationRecommendationError.insufficientSpace(
          requiredBytes: 40_000_000_000, availableBytes: available)
        await session.inspect()
        await session.continueToPlan()

        guard case .failed(let failure) = session.phase else {
          return XCTFail("Expected a space shortfall during planning.")
        }
        XCTAssertEqual(failure.headline, "Free up at least \(expectedGB) GB to install Omarchy")
        XCTAssertTrue(session.canInspect)
        XCTAssertFalse(session.canStartInstallation)
        session.approve()
        session.presentInstallCredentials()
        XCTAssertNil(session.credentialSheet.context)
        XCTAssertFalse(environment.hasApprovedPlan)
        XCTAssertFalse(session.hasExecutionStarted)
      }

      environment.prepareError = nil
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("A successful recheck should allow a fresh plan review.")
      }
      XCTAssertFalse(acknowledged)
      XCTAssertFalse(session.canStartInstallation)
    }

    func testSnapshotFailureAllowsRecheckingWithoutAuthorizingInstallation() async {
      let environment = MockInstallerEnvironment()
      environment.prepareError =
        InstallerAllocationRecommendationError.snapshotConstrained(.timeMachine)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()

      guard case .failed(let failure) = session.phase else {
        return XCTFail("Expected a snapshot preparation failure.")
      }
      XCTAssertEqual(
        failure.actionURL,
        URL(string: "https://support.apple.com/en-us/102154")
      )
      XCTAssertTrue(session.canInspect)
      XCTAssertFalse(session.canStartInstallation)
      session.approve()
      session.presentInstallCredentials()
      XCTAssertNil(session.credentialSheet.context)
      XCTAssertFalse(environment.hasApprovedPlan)
      XCTAssertFalse(session.hasExecutionStarted)

      environment.prepareError = nil
      await session.inspect()
      guard case .welcome = session.phase else {
        return XCTFail("Rechecking should return to the welcome step.")
      }
      await session.continueToPlan()
      session.continueToPlanReview()
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("A successful recheck should allow a fresh plan review.")
      }
      XCTAssertFalse(acknowledged)
      XCTAssertFalse(session.canStartInstallation)
    }

    private func authorization() throws -> MachineOwnerAuthorization {
      try MachineOwnerAuthorization(
        username: "owner",
        password: Data("secret".utf8)
      )
    }

    private func waitUntil(
      _ predicate: @escaping @MainActor () -> Bool
    ) async {
      for _ in 0..<200 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(10))
      }
    }

    // MARK: Existing install

    func testAnExistingInstallIsRefusedBeforeAnythingIsFetched() async {
      let environment = MockInstallerEnvironment()
      let install = ExistingInstallDisplay(
        sourceIdentifier: "disk0s3",
        sizeDescription: "128 GB"
      )
      environment.host = HostDisplay(
        chipAndSpace: MockInstallerEnvironment.supportedHost.chipAndSpace,
        supported: true,
        existingInstalls: [install]
      )
      let session = InstallerSession(environment: environment)
      await session.inspect()

      guard case .existingInstallRefused(let host) = session.phase else {
        return XCTFail("Expected existingInstallRefused, got \(session.phase)")
      }
      XCTAssertEqual(host.existingInstalls, [install])
      // Nothing was planned, so nothing was fetched.
      XCTAssertEqual(environment.prepareCount, 0)

      await session.continueToPlan()
      session.setAcknowledged(true)
      session.approve()
      guard case .existingInstallRefused = session.phase else {
        return XCTFail("Expected the refusal to stay, got \(session.phase)")
      }
      XCTAssertEqual(environment.prepareCount, 0)
      XCTAssertFalse(session.canStartInstallation)
    }

    func testAnExistingInstallFoundWhilePlanningIsRefusedToo() async {
      let environment = MockInstallerEnvironment()
      let install = ExistingInstallDisplay(
        sourceIdentifier: "disk0s3",
        sizeDescription: "128 GB"
      )
      environment.existingInstalls = [install]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()

      guard case .existingInstallRefused = session.phase else {
        return XCTFail("Expected existingInstallRefused, got \(session.phase)")
      }
      XCTAssertEqual(environment.prepareCount, 1)
    }

    /// On the M2 Max (apple,j414c, enabled in the signed catalog) the header
    /// said NOT SUPPORTED because an older install was still on the disk. Only
    /// a refused model says that; a stop for any other reason says Supported
    /// when the Mac is, and nothing when the installer couldn't tell.
    func testHeaderSaysNotSupportedOnlyForARefusedModel() async {
      let supported = MockInstallerEnvironment.supportedHost
      let install = ExistingInstallDisplay(sourceIdentifier: "disk0s3", sizeDescription: "256 GB")
      let cases: [(String, HostDisplay, Bool, Bool?)] = [
        ("ready", supported, false, true),
        (
          "existing install on a supported Mac",
          HostDisplay(
            chipAndSpace: supported.chipAndSpace, supported: true, existingInstalls: [install]),
          false, true
        ),
        (
          "existing install, engine couldn't tell",
          HostDisplay(
            chipAndSpace: supported.chipAndSpace, supported: false, existingInstalls: [install]),
          false, nil
        ),
        (
          "too little space",
          HostDisplay(
            chipAndSpace: supported.chipAndSpace, supported: true,
            spaceShortfall: .insufficientSpace(
              requiredBytes: 76_562_825_216, availableBytes: 73_528_246_272)),
          false, true
        ),
        (
          "not ready",
          HostDisplay(
            chipAndSpace: supported.chipAndSpace, supported: false,
            blockingReason: "The installer engine is unavailable."),
          false, nil
        ),
        (
          "model not in the catalog",
          HostDisplay(
            chipAndSpace: "Apple M3 · 400 GB free", supported: false,
            unsupportedModel: UnsupportedModelDisplay(
              deviceIdentifier: "apple,j504", modelIdentifier: "Mac15,3",
              supportedDeviceIdentifiers: ["apple,j314s"])),
          false, false
        ),
        ("blocked model", HostDisplay(chipAndSpace: "Apple M4 Pro", supported: false), true, false),
      ]
      for (name, host, blocked, expected) in cases {
        let environment = MockInstallerEnvironment()
        environment.host = host
        environment.installationBlocked = blocked
        let session = InstallerSession(environment: environment)
        await session.inspect()
        XCTAssertEqual(session.modelSupported, expected, name)
      }
    }

    func testReinspectResetsDisplayedAndStoredEncryptionChoice() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setEncryptLinuxDisk(false)
      XCTAssertFalse(session.encryptLinuxDisk)
      XCTAssertFalse(environment.storedEncryptLinuxDisk)

      await session.inspect()

      XCTAssertTrue(session.encryptLinuxDisk)
      XCTAssertTrue(environment.storedEncryptLinuxDisk)
    }

    func testInstallReadsEncryptionChoiceFromTheSession() async throws {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setEncryptLinuxDisk(false)
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      await session.submit(try authorization())
      XCTAssertEqual(environment.lastEncryptLinuxDisk, false)
    }

    func testAwaitingRecoveryRendersTheHandoffWarning() async throws {
      let environment = MockInstallerEnvironment()
      var completion = MockInstallerEnvironment.recoveryCompletion
      completion = CompletionDisplay(
        nextAction: completion.nextAction,
        headline: completion.headline,
        subheadline: PlainLanguage.nextActionMessage(
          .enterRecovery, installConf: .notRecorded),
        verified: completion.verified,
        handoff: HandoffDisplay(
          headline: completion.handoff!.headline,
          steps: completion.handoff!.steps,
          warning: PlainLanguage.encryptionChoiceNotRecorded
        )
      )
      environment.executeResults = [.success(completion)]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      await session.submit(try authorization())
      guard case .awaitingRecovery(let handoff) = session.phase else {
        return XCTFail("Expected awaitingRecovery, got \(session.phase)")
      }
      XCTAssertEqual(handoff.warning, PlainLanguage.encryptionChoiceNotRecorded)
    }

    func testRecoveryRetrySubmitStillUsesTheSessionEncryptionChoice() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.recoveryAuthorizationFailed),
        .success(MockInstallerEnvironment.recoveryCompletion),
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setEncryptLinuxDisk(false)
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      await session.submit(try authorization())
      session.presentRecoveryRetryCredentials()
      await session.submit(try authorization())
      XCTAssertEqual(environment.lastOperation, .retryRecoveryAuthorization)
      XCTAssertEqual(environment.lastEncryptLinuxDisk, false)
    }
  }

  actor OperationGate {
    private var entered = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      entered = true
      await withCheckedContinuation { continuations.append($0) }
    }
    func waitUntilEntered() async {
      while !entered { await Task.yield() }
    }
    func release() {
      for continuation in continuations { continuation.resume() }
      continuations.removeAll()
    }
  }

  final class MockInstallerEnvironment: InstallerEnvironment, @unchecked Sendable {
    var accountReply: RecoveryAccountReply? = RecoveryAccountReply(
      ticket: "completed-install",
      target: RecoveryAccountTarget(
        volumeName: "Omarchy", systemUUID: "11111111-1111-4111-8111-111111111111",
        dataUUID: "22222222-2222-4222-8222-222222222222",
        groupUUID: "33333333-3333-4333-8333-333333333333",
        prebootUUID: "44444444-4444-4444-8444-444444444444"))
    var accountCalls = [String]()
    var handoffFails = false
    var handoffOverride: RecoveryAccountReply?
    func prepareRecoveryHandoff(ticket: String) async throws -> RecoveryAccountReply {
      accountCalls.append("handoff:\(ticket)")
      if handoffFails { throw AccountSetupFailure("fixture failure") }
      return handoffOverride ?? accountReply!
    }
    func inspectRecoveryAccount() async throws -> RecoveryAccountReply? {
      accountCalls.append("inspect")
      return accountReply
    }
    func prepareRecoveryAccount(ticket: String, username: String, password: Data) async throws
      -> RecoveryAccountReply
    {
      accountCalls.append("prepare:\(ticket):\(username)")
      return accountReply!
    }
    var host = MockInstallerEnvironment.supportedHost
    var plan = MockInstallerEnvironment.samplePlan
    var helper = HelperDisplay(status: .current)
    var installationBlocked = false
    var engineSupported = true
    var requestShutdownCount = 0
    var shutdownAccepted = false
    var inspectGate: OperationGate?
    var prepareGate: OperationGate?
    var executeGate: OperationGate?
    var savedProgress: (@Sendable (AssetProgressUpdate) -> Void)?
    var savedJournal: (@Sendable (Data) -> Void)?
    var inspectError: (any Error)?
    var prepareError: (any Error)?
    var approveError: (any Error)?
    var executeResults = [Result<CompletionDisplay, any Error>]()
    var journalChunks = [Data]()
    var progressUpdates = [AssetProgressUpdate]()
    var existingInstalls = [ExistingInstallDisplay]()

    private(set) var approveCount = 0
    private(set) var discardCount = 0
    private(set) var executeCount = 0
    /// Each helper setup, as the order of calls relative to execute.
    private(set) var calls = [String]()
    var ensureHelperError: (any Error)?
    private(set) var prepareCount = 0
    private(set) var lastOperation: InstallOperationKind?
    private(set) var lastEncryptLinuxDisk: Bool?
    private(set) var storedEncryptLinuxDisk = true
    private var approved = false

    var hasApprovedPlan: Bool { approved }
    var helperStatus: HelperDisplay { helper }

    /// One answer per channel check, in order; a gate holds that check open.
    var availabilityAnswers = [[ReleaseChannel: ReleaseChannelAvailability]]()
    var availabilityGates = [OperationGate?]()
    private var availabilityChecks = 0

    func channelAvailability() async -> [ReleaseChannel: ReleaseChannelAvailability] {
      let check = availabilityChecks
      availabilityChecks += 1
      if check < availabilityGates.count { await availabilityGates[check]?.wait() }
      return check < availabilityAnswers.count ? availabilityAnswers[check] : [:]
    }

    func inspect() async throws -> HostDisplay {
      await inspectGate?.wait()
      approved = false
      if let inspectError {
        throw inspectError
      }
      return host
    }

    var lastOmarchyBytes: UInt64?
    var payloadPrefetchRequired = false
    var prefetchGate: OperationGate?
    private(set) var prefetchStartCount = 0
    private(set) var prefetchCancelCount = 0
    /// The live environment begins the download inside preparation, so a
    /// cancel after this count stops a download the preparation started.
    private(set) var cancelsBeforePrepare = 0
    var prefetchFailure = false
    var payloadPrefetchState: PayloadPrefetchState = .idle

    func preparePlan(
      omarchyBytes: UInt64?,
      progress: @escaping @Sendable (AssetProgressUpdate) -> Void
    ) async throws -> PlanPreparationDisplay {
      savedProgress = progress
      await prepareGate?.wait()
      prepareCount += 1
      cancelsBeforePrepare = prefetchCancelCount
      lastOmarchyBytes = omarchyBytes
      approved = false
      for update in progressUpdates {
        progress(update)
        await Task.yield()
      }
      if let prepareError {
        throw prepareError
      }
      if !existingInstalls.isEmpty {
        return .existingInstallChoice(existingInstalls)
      }
      return .plan(plan)
    }

    func approve() throws {
      if let approveError {
        throw approveError
      }
      approveCount += 1
      approved = true
    }

    func discardApproval() {
      discardCount += 1
      approved = false
    }

    func refreshHelperStatus() -> HelperDisplay { helper }

    /// What the helper itself reports; nil reports the registration status.
    var probedHelper: HelperDisplay?

    func probeHelperStatus() async -> HelperDisplay { probedHelper ?? helper }

    func ensureHelper(
      _ authorization: MachineOwnerAuthorization, reenablingSwitchedOff: Bool
    ) async throws {
      calls.append(
        "ensureHelper:\(authorization.username)" + (reenablingSwitchedOff ? ":reenable" : ""))
      if let ensureHelperError {
        self.ensureHelperError = nil
        throw ensureHelperError
      }
    }

    func requestShutdown() -> Bool {
      requestShutdownCount += 1
      return shutdownAccepted
    }

    func setEncryptLinuxDisk(_ encrypt: Bool) {
      storedEncryptLinuxDisk = encrypt
    }

    func prefetchPayload(
      progress: @escaping @Sendable (PayloadPrefetchState) -> Void
    ) async throws {
      prefetchStartCount += 1
      progress(.idle)
      let fails = prefetchFailure
      await prefetchGate?.wait()
      if fails { throw PayloadPrefetchError.failed("retry") }
      payloadPrefetchState = .verified
      progress(.verified)
    }

    func waitUntilPayloadVerified() async throws {
      await prefetchGate?.wait()
    }

    func cancelPayloadPrefetch() {
      prefetchCancelCount += 1
    }

    private(set) var prefetchRestartCount = 0
    func restartPayloadPrefetch() {
      prefetchRestartCount += 1
    }

    func execute(
      operation: InstallOperationKind,
      authorization: MachineOwnerAuthorization,
      encryptLinuxDisk: Bool,
      journal: @escaping @Sendable (Data) -> Void
    ) async throws -> CompletionDisplay {
      executeCount += 1
      calls.append("execute")
      lastEncryptLinuxDisk = encryptLinuxDisk
      savedJournal = journal
      await executeGate?.wait()
      lastOperation = operation
      for chunk in journalChunks {
        journal(chunk)
        await Task.yield()
      }
      // Give the session's main-actor hops a chance to land.
      try? await Task.sleep(for: .milliseconds(20))
      if executeResults.isEmpty {
        return Self.recoveryCompletion
      }
      return try executeResults.removeFirst().get()
    }

    static let supportedHost = HostDisplay(
      chipAndSpace: "Apple M1 Pro · 464 GB free",
      supported: true
    )

    static let blockedHost = HostDisplay(
      chipAndSpace: "Apple M4 · apple,j614s",
      supported: false
    )

    static let samplePlan = PlanDisplay(
      diskTotalBytes: 994_662_584_320,
      omarchyBytes: 137_438_953_472,
      bindingDigest: "sha256:" + String(repeating: "b", count: 64)
    )

    static let recoveryCompletion = CompletionDisplay(
      nextAction: .enterRecovery,
      headline: PlainLanguage.recoveryHeadline,
      subheadline: PlainLanguage.nextActionMessage(.enterRecovery),
      verified: PlainLanguage.doneVerifiedRows,
      handoff: HandoffDisplay(
        headline: PlainLanguage.recoveryHeadline,
        steps: PlainLanguage.recoverySteps(for: [
          "enterOneTrueRecovery", "authenticateMachineOwner",
        ])
      )
    )
  }
#endif
