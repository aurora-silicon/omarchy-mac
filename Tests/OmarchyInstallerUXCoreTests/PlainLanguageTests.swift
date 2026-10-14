#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  final class PlainLanguageTests: XCTestCase {
    func testPreSubmissionHelperFailureKeepsSpecificRecoveryAdvice() throws {
      let failure = PlainLanguage.failure(
        for: InstallerPreSubmissionFailure(EngineXPCSubmissionError.helperUnresponsive))
      XCTAssertEqual(failure.headline, "The installation service isn’t responding")
      XCTAssertTrue(try XCTUnwrap(failure.remedy).contains("again, then reopen this app"))
      XCTAssertFalse(try XCTUnwrap(failure.remedy).contains("Check again"))
      XCTAssertTrue(failure.plainDetail.contains("not started"))
      for error in [EngineXPCSubmissionError.helperUnresponsive, .connectionFailed] {
        let retry = PlainLanguage.failure(
          for: InstallerPreSubmissionFailure(error), retryRecoveryAvailable: true)
        XCTAssertEqual(retry.headline, failure.headline)
        XCTAssertEqual(retry.remedy, failure.remedy)
        XCTAssertTrue(retry.retryRecoveryAvailable)
        XCTAssertTrue(retry.plainDetail.contains("checkpoint is preserved"))
        XCTAssertFalse(retry.plainDetail.contains("not started"))
      }
    }

    func testPreparedResumeMismatchExplainsCompletedWorkWithoutUnsafeRetry() throws {
      let notice = EngineFailureNotice(
        reason: EngineFailureReason(rawValue: 5) ?? .unclassified,
        exitStatus: 1, diskUnchanged: false,
        summary: "prepared resume target does not match checkpoint")
      let failure = PlainLanguage.failure(for: EngineXPCSubmissionError.engineFailed(notice))
      XCTAssertEqual(
        failure.headline, "The prepared installation no longer matches its saved checkpoint")
      XCTAssertTrue(failure.plainDetail.contains("already prepared disk space"))
      XCTAssertTrue(failure.plainDetail.contains("No further installation step"))
      XCTAssertTrue(try XCTUnwrap(failure.remedy).contains("journal"))
      XCTAssertFalse(failure.replanAvailable)
      XCTAssertFalse(failure.retryRecoveryAvailable)
    }

    func testSpaceCautionsFollowAllocationAndReserveBoundary() {
      let plan = PlanDisplay(
        diskTotalBytes: 245_000_000_000, omarchyBytes: 40_000_000_000,
        bindingDigest: "test", macOSFreeBeforeAllocationBytes: 80_000_000_000,
        recommendedOmarchyBytes: 77_000_000_000)
      XCTAssertEqual(
        plan.spaceCautions(for: 40_000_000_000),
        ["Omarchy will use its minimum size, 40 GB, leaving little room for updates and snapshots."]
      )
      XCTAssertEqual(plan.spaceCautions(for: 42_000_000_000).count, 1)
      XCTAssertNil(plan.macOSSpaceCaution(for: 42_000_000_000))
      XCTAssertEqual(
        plan.macOSSpaceCaution(for: 42_000_000_001),
        plan.spaceCautions(for: 42_000_000_001).first)
      XCTAssertEqual(
        plan.spaceCautions(for: 42_000_000_001)[0],
        "macOS will have about 37 GB free, less than the recommended 38 GB. You may need to free up space in macOS before an update will install."
      )
      let warnings = plan.spaceCautions(for: 43_000_000_000)
      XCTAssertEqual(warnings.count, 2)
      XCTAssertEqual(
        warnings[1],
        "Omarchy will use 43 GB, less than the recommended 77 GB, leaving limited room for updates and snapshots."
      )
      XCTAssertEqual(plan.spaceCautions(for: 77_000_000_000).count, 1)
      let free = PlanDisplay(
        diskTotalBytes: 245_000_000_000, omarchyBytes: 40_000_000_000,
        bindingDigest: "free", fixedMacOSBytes: 180_000_000_000,
        recommendedOmarchyBytes: 77_000_000_000)
      XCTAssertNil(free.macOSSpaceCaution(for: 77_000_000_000))
      XCTAssertEqual(free.spaceCautions(for: 40_000_000_000).count, 1)
      XCTAssertTrue(free.spaceCautions(for: 77_000_000_000).isEmpty)
    }

    func testHeaderNamesTheChosenSizeOnceThereIsOne() {
      let host = HostDisplay(
        chipAndSpace: "Apple M2 Max · 375 GB free · up to 314 GB for Omarchy",
        chipAndFreeSpace: "Apple M2 Max · 375 GB free",
        supported: true)
      XCTAssertEqual(
        host.header(chosenOmarchyBytes: nil),
        "Apple M2 Max · 375 GB free · up to 314 GB for Omarchy")
      XCTAssertEqual(
        host.header(chosenOmarchyBytes: 285_000_000_000),
        "Apple M2 Max · 375 GB free · \(PlainLanguage.bytes(285_000_000_000)) for Omarchy")
    }

    func testHeaderWithoutSeparateFreeSpaceStillNamesTheChosenSize() {
      let host = HostDisplay(chipAndSpace: "Simulated Mac · 464 GB free", supported: true)
      XCTAssertEqual(
        host.header(chosenOmarchyBytes: 100_000_000_000),
        "Simulated Mac · 464 GB free · \(PlainLanguage.bytes(100_000_000_000)) for Omarchy")
    }

    func testChannelBadgesNameEveryChannel() {
      XCTAssertEqual(PlainLanguage.badge(for: .stable), "Stable")
      XCTAssertEqual(PlainLanguage.badge(for: .rc), "Release candidate")
      XCTAssertEqual(PlainLanguage.badge(for: .edge), "Edge")
    }

    func testChannelMenuItemsNameTheThreeStatesApart() {
      XCTAssertEqual(PlainLanguage.channelMenuItem(.edge, availability: nil), "Edge")
      XCTAssertEqual(PlainLanguage.channelMenuItem(.edge, availability: .available), "Edge")
      XCTAssertEqual(
        PlainLanguage.channelMenuItem(.stable, availability: .noRelease),
        "Stable — No Mac release yet")
      XCTAssertEqual(
        PlainLanguage.channelMenuItem(
          .rc, availability: .modelUnavailable(supportedDeviceIdentifiers: ["apple,j274"])),
        "Release candidate — Not available for this Mac")
      XCTAssertEqual(
        PlainLanguage.channelMenuItem(.rc, availability: .checkFailed(.network)),
        "Release candidate — Couldn’t load")
      XCTAssertEqual(
        PlainLanguage.channelMenuItem(.rc, availability: .checkFailed(.verification)),
        "Release candidate — Couldn’t verify")
    }

    func testOnlyChannelsWithNothingForThisMacAreDisabled() {
      func enabled(_ channel: ReleaseChannel, _ availability: ReleaseChannelAvailability?) -> Bool {
        PlainLanguage.channelMenuItemEnabled(channel, selected: .edge, availability: availability)
      }
      XCTAssertFalse(enabled(.stable, .noRelease))
      XCTAssertFalse(enabled(.rc, .modelUnavailable(supportedDeviceIdentifiers: [])))
      XCTAssertTrue(enabled(.rc, .checkFailed(.network)))
      XCTAssertTrue(enabled(.rc, .checkFailed(.verification)))
      XCTAssertTrue(enabled(.rc, .available))
      XCTAssertTrue(enabled(.rc, nil))
      // The channel in use stays chosen whatever it offers.
      XCTAssertTrue(enabled(.edge, .noRelease))
    }

    func testNoMacReleaseReadsApartFromAMissingModelAndAServerFailure() {
      let noRelease = PlainLanguage.failure(for: InstallerAssetPreparationError.noMacRelease)
      XCTAssertEqual(noRelease.headline, "No Mac release on this channel yet")
      XCTAssertFalse(noRelease.isBlockedModel)
      XCTAssertTrue(try XCTUnwrap(noRelease.remedy).contains("Release channel menu"))

      let notListed = PlainLanguage.failure(
        for: InstallerAssetPreparationError.notInCatalog(
          deviceIdentifier: "apple,j504", modelIdentifier: "Mac15,3",
          supportedDeviceIdentifiers: ["apple,j274"]))
      XCTAssertTrue(notListed.isBlockedModel)

      let missing = PlainLanguage.failure(
        for: InstallerReleaseConfigurationError.unexpectedHTTPStatus(404))
      let unverified = PlainLanguage.failure(
        for: InstallerReleaseConfigurationError.invalidCatalogSignature)
      let headlines = [
        noRelease.headline, notListed.headline, missing.headline, unverified.headline,
      ]
      XCTAssertEqual(Set(headlines).count, headlines.count)
      // A missing channel object is a server problem, never "no release".
      XCTAssertFalse(missing.headline.localizedCaseInsensitiveContains("no release"))
      XCTAssertFalse(
        missing.plainDetail.localizedCaseInsensitiveContains("no downloadable release"))
    }

    func testAllocationNoticeIgnoresByteAlignmentAtDisplayedPrecision() {
      XCTAssertNil(
        PlainLanguage.allocationNotice(
          requestedBytes: 180_000_000_000, actualBytes: 179_999_604_736))
      XCTAssertNil(
        PlainLanguage.allocationNotice(
          requestedBytes: 180_000_000_000, actualBytes: 180_000_000_000))
    }

    func testAllocationNoticeDescribesActualChangeWithoutClaimingDiskIsFull() {
      XCTAssertEqual(
        PlainLanguage.allocationNotice(
          requestedBytes: 650_000_000_000, actualBytes: 137_438_953_472),
        "Space for Omarchy changed from 650 GB to 137 GB. Review the updated size before installing."
      )
      XCTAssertEqual(
        PlainLanguage.allocationNotice(requestedBytes: 70_000_000_000, actualBytes: 80_000_000_000),
        "Space for Omarchy changed from 70 GB to 80 GB. Review the updated size before installing.")
    }

    func testApprovedSpaceChangeOffersReplanOnlyWhenTheDiskIsProvenUnchanged() {
      let unchanged = PlainLanguage.failure(
        for: EngineXPCSubmissionError.engineFailed(
          EngineFailureNotice(
            reason: .approvedSpaceChanged, exitStatus: 1, diskUnchanged: true,
            summary: "omarchy_execution.ExecutionAdmissionError: approved extent changed")))
      XCTAssertEqual(unchanged.headline, "The space available for Omarchy changed")
      XCTAssertTrue(unchanged.plainDetail.contains("No disk changes were made."))
      XCTAssertTrue(unchanged.replanAvailable)
      XCTAssertTrue(try XCTUnwrap(unchanged.technicalDetail).contains("approved extent changed"))

      let unknown = PlainLanguage.failure(
        for: EngineXPCSubmissionError.engineFailed(
          EngineFailureNotice(
            reason: .approvedSpaceChanged, exitStatus: 1, diskUnchanged: false, summary: "")))
      XCTAssertFalse(unknown.plainDetail.contains("No disk changes were made."))
      XCTAssertFalse(unknown.replanAvailable)
    }

    func testEveryEngineFailureReasonHasPlainWording() {
      for reason in EngineFailureReason.allCases {
        for unchanged in [true, false] {
          let display = PlainLanguage.engineFailure(
            EngineFailureNotice(
              reason: reason, exitStatus: 1, diskUnchanged: unchanged, summary: ""),
            technicalDetail: "detail")
          XCTAssertFalse(display.headline.isEmpty)
          XCTAssertEqual(
            display.plainDetail.contains("No disk changes were made."), unchanged, "\(reason)")
          XCTAssertEqual(
            display.replanAvailable,
            unchanged && (reason == .approvedSpaceChanged || reason == .diskLayoutChanged))
        }
      }
    }

    func testUnsupportedModelNamesTheMacAndTheCatalogFamilies() throws {
      let display = PlainLanguage.failure(
        for: InstallerAssetPreparationError.notInCatalog(
          deviceIdentifier: "apple,j504",
          modelIdentifier: "Mac15,3",
          supportedDeviceIdentifiers: ["apple,j314s", "apple,j416c", "apple,j274", "apple,j999"]))
      XCTAssertTrue(display.isBlockedModel)
      XCTAssertEqual(
        display.plainDetail,
        "This Mac (MacBook Pro 14-inch (M3, 2023) · Mac15,3 · apple,j504) isn’t included in this release."
      )
      let remedy = try XCTUnwrap(display.remedy)
      XCTAssertTrue(
        remedy.hasPrefix(
          "This release supports these Macs (4 models): M1: Mac mini, MacBook Pro. M2: MacBook Pro. also apple,j999."
        ), remedy)
    }

    func testUnsupportedModelWithoutACatalogStillNamesTheMac() {
      let display = PlainLanguage.failure(
        for: ClosedEngineHelperError.unsupportedDevice("apple,j614s"))
      XCTAssertTrue(display.isBlockedModel)
      XCTAssertTrue(
        display.plainDetail.contains("MacBook Pro 14-inch (M4 Pro, 2024) · apple,j614s"))
      XCTAssertEqual(display.remedy, PlainLanguage.blockedExplainer)
      let unknown = PlainLanguage.unsupportedModel(
        deviceIdentifier: "apple,j999", modelIdentifier: "Mac99,1")
      XCTAssertEqual(
        unknown.plainDetail, "This Mac (Mac99,1 · apple,j999) isn’t included in this release.")
    }

    func testFriendlyNamesCoverEveryModelTheReleaseTemplatesList() throws {
      let scripts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts")
      var identifiers = Set<String>()
      for name in ["release-inputs.template.json", "release-inputs-aurora.template.json"] {
        let text = try String(
          contentsOf: scripts.appendingPathComponent(name), encoding: .utf8)
        for match in text.matches(of: /"(apple,j[0-9a-z]+)"/) {
          identifiers.insert(String(match.1))
        }
      }
      let everyM1M2M3Mac = [
        "j274", "j293", "j313", "j456", "j457", "j314s", "j314c", "j316s", "j316c", "j375c",
        "j375d", "j413", "j415", "j473", "j493", "j414s", "j414c", "j416s", "j416c", "j474s",
        "j475c", "j475d", "j180d", "j433", "j434", "j504", "j613", "j615", "j514s", "j514c",
        "j514m", "j516s", "j516c", "j516m",
      ].map { "apple,\($0)" }
      XCTAssertEqual(identifiers, Set(everyM1M2M3Mac))
      let manifest = try JSONSerialization.jsonObject(
        with: Data(contentsOf: scripts.appendingPathComponent("supported-models.json")))
      let supported = try XCTUnwrap((manifest as? [String: Any])?["supported"] as? [String])
      XCTAssertEqual(Set(supported), Set(everyM1M2M3Mac))
      #if DEBUG
        XCTAssertEqual(
          InstallerSimulationEnvironment.simulatedCatalogDevices.sorted(), everyM1M2M3Mac.sorted())
      #endif
      for identifier in identifiers {
        XCTAssertNotNil(MacModelNames.name(for: identifier), identifier)
      }
    }

    func testTheMacBookNeoHasAName() {
      XCTAssertEqual(MacModelNames.name(for: "apple,j700"), "MacBook Neo (A18 Pro, 2026)")
      XCTAssertEqual(
        MacModelNames.supportedFamiliesSummary(["apple,j700"]), "A18 Pro: MacBook Neo")
    }

    func testEveryPhaseHasADistinctTitle() {
      let phases = [
        "preflight", "existing_removal", "apfs_preparation", "stub_and_esp",
        "awaiting_recovery", "boot_policy", "media_handoff", "omarchy_install",
      ]
      let titles = phases.map { PlainLanguage.installPhaseTitle(forPhase: $0) }

      XCTAssertEqual(Set(titles).count, phases.count)
      XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
      XCTAssertEqual(
        PlainLanguage.installPhaseTitle(forPhase: nil),
        PlainLanguage.installVerifyingOwner
      )
    }

    func testEveryStartedEventHasATitle() {
      for event in [
        "existing_removal_started", "apfs_preparation_started",
        "stub_and_esp_started", "recovery_handoff_started",
      ] {
        XCTAssertNotNil(PlainLanguage.installPhaseTitle(forEvent: event))
        XCTAssertFalse(PlainLanguage.eventSummary(event).isEmpty)
      }
      XCTAssertNil(PlainLanguage.installPhaseTitle(forEvent: "unknown_event"))
      XCTAssertEqual(
        PlainLanguage.eventSummary("odd_name"), "Additional installation activity (odd_name)")
    }

    func testEveryCheckpointHasAPlainSummary() {
      let identifiers = [
        "existing-install-removed", "apfs-target-prepared",
        "stub-and-esp-installed", "recovery-handoff-prepared",
      ]
      let summaries = identifiers.map(PlainLanguage.checkpointSummary)

      XCTAssertEqual(Set(summaries).count, identifiers.count)
      XCTAssertTrue(summaries.allSatisfy { !$0.isEmpty })
      XCTAssertEqual(
        PlainLanguage.checkpointSummary("unknown"), "Additional installation activity (unknown)")
    }

    func testEveryNextActionHasAMessage() {
      let actions: [InstallerNextAction] = [
        .continueInstallation, .enterRecovery, .attachInstallationMedia,
        .verifyInstalledSystem, .manualRecovery,
      ]
      let messages = actions.map { PlainLanguage.nextActionMessage($0) }

      XCTAssertEqual(Set(messages).count, actions.count)
      XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }

    func testRecoveryStepsCoverSignedTokensAndUnknowns() {
      let steps = PlainLanguage.recoverySteps(for: [
        "enterOneTrueRecovery", "authenticateMachineOwner",
      ])
      XCTAssertEqual(steps.count, 3)
      XCTAssertEqual(steps.map(\.number), [1, 2, 3])
      XCTAssertTrue(steps.allSatisfy { !($0.detail ?? "").isEmpty })

      let unknown = PlainLanguage.recoverySteps(for: ["somethingNew"])
      XCTAssertEqual(unknown.count, 1)
      XCTAssertEqual(unknown.first?.title, "Unsupported Recovery instruction: somethingNew")
      XCTAssertEqual(
        unknown.first?.detail,
        "Save the installation record and get support before continuing."
      )

      XCTAssertEqual(PlainLanguage.recoverySteps(for: []), steps)
    }

    func testKnownErrorsMapToDistinctHeadlinesAndKeepTechnicalDetail() {
      let errors: [any Error] = [
        EngineXPCSubmissionError.machineOwnerCredentialsRejected,
        EngineXPCSubmissionError.connectionFailed,
        EngineXPCSubmissionError.recoveryAuthorizationFailed,
        ClosedEngineHelperError.busy,
        ClosedEngineHelperError.unsupportedDevice("apple,j614s"),
        InstallerPlanPreparationError.inventoryUnavailable,
        ArtifactStageError.digestMismatch(expected: "a", actual: "b"),
        InstallerReleaseConfigurationError.releaseResourcesUnavailable,
        SupportCatalogError.expired,
        InstallerAssetPreparationError.hostBlocked("not enabled"),
        InstallerAssetPreparationError.unsupportedDevice("apple,j614s"),
        InstallerAssetPreparationError.deliveryMetadataUnavailable,
        InstallerAppErrorStub.unknown,
      ]

      var headlines = Set<String>()
      for error in errors {
        let failure = PlainLanguage.failure(for: error)
        XCTAssertFalse(failure.headline.isEmpty)
        XCTAssertFalse(failure.plainDetail.isEmpty)
        XCTAssertEqual(failure.technicalDetail, String(describing: error))
        headlines.insert(failure.headline)
      }
      XCTAssertGreaterThanOrEqual(headlines.count, 8)
    }

    func testAnInstallRefusedForAnEarlierRemovalSaysWhyAndHowToRecover() {
      for (helperError, headline) in [
        (
          ClosedEngineHelperError.earlierRemovalUnfinished,
          PlainLanguage.earlierRemovalUnfinishedHeadline
        ),
        (.earlierInstallRecordUncleared, PlainLanguage.earlierInstallRecordUnclearedHeadline),
      ] {
        let bridged = helperError as NSError
        // Over XPC the app sees the helper's error by domain and code.
        for error in [
          helperError as any Error,
          EngineXPCSubmissionError.helperRejected(domain: bridged.domain, code: bridged.code),
        ] {
          let failure = PlainLanguage.failure(for: error)
          XCTAssertEqual(failure.headline, headline, "\(error)")
          XCTAssertTrue(failure.plainDetail.contains("nothing was changed"), failure.plainDetail)
          XCTAssertTrue(
            failure.remedy?.contains(InstallerProductIdentity.helperWorkingDirectory) == true)
        }
      }
    }

    func testAnOutdatedInstallerOffersTheDownloadItNeeds() {
      let url = URL(
        string: "https://downloads.example.com/installer/stable/Installer.pkg"
      )!
      let failure = PlainLanguage.failure(
        for: InstallerAssetPreparationError.installerOutdated(
          current: InstallerVersion("1.9.9")!,
          minimum: InstallerVersion("2.0.0")!,
          downloadURL: url
        )
      )

      XCTAssertEqual(failure.headline, "This installer is out of date")
      XCTAssertTrue(failure.plainDetail.contains("2.0.0"))
      XCTAssertTrue(failure.plainDetail.contains("1.9.9"))
      XCTAssertTrue(failure.plainDetail.contains("requires installer"))
      XCTAssertEqual(failure.actionURL, url)
      XCTAssertEqual(failure.actionTitle, PlainLanguage.downloadInstaller)
      XCTAssertFalse(failure.retryRecoveryAvailable)
    }

    func testFailuresWithoutAnActionCarryNoLink() {
      let failure = PlainLanguage.failure(for: SupportCatalogError.expired)

      XCTAssertNil(failure.actionURL)
      XCTAssertNil(failure.actionTitle)
    }

    func testConfirmedSnapshotConstraintsOfferAppleGuidanceWithoutRecoveryAuthorization() {
      for constraint: APFSSnapshotConstraint in [.timeMachine, .other] {
        let failure = PlainLanguage.failure(
          for: InstallerAllocationRecommendationError.snapshotConstrained(constraint)
        )

        XCTAssertEqual(
          failure.actionURL,
          URL(string: "https://support.apple.com/en-us/102154")
        )
        XCTAssertFalse(failure.retryRecoveryAvailable)
        XCTAssertFalse(failure.isBlockedModel)
      }
    }

    func testUnconfirmedAllocationFailureDoesNotOfferSnapshotCleanupAsTheFix() {
      let failure = PlainLanguage.failure(
        for: InstallerAllocationRecommendationError.noEligibleCandidate
      )

      XCTAssertNil(failure.actionURL)
      XCTAssertFalse(failure.retryRecoveryAvailable)
    }

    /// An empty channel serves a signed empty catalog; a missing channel
    /// object is a server problem, reported without its status code.
    func testAMissingChannelObjectSaysSoInsteadOfShowingAStatusCode() {
      let failure = PlainLanguage.failure(
        for: InstallerReleaseConfigurationError.unexpectedHTTPStatus(404)
      )

      XCTAssertEqual(failure.headline, "This channel’s release list wasn’t found")
      XCTAssertTrue(failure.plainDetail.contains("can’t tell what the channel offers"))
      XCTAssertFalse(failure.plainDetail.contains("404"))
      XCTAssertFalse(failure.headline.contains("404"))
      XCTAssertEqual(
        failure.technicalDetail,
        String(describing: InstallerReleaseConfigurationError.unexpectedHTTPStatus(404))
      )
      XCTAssertTrue(try XCTUnwrap(failure.remedy).contains("release channel"))
    }

    func testOtherServerFailuresAreDistinctFromAnEmptyChannel() {
      let failure = PlainLanguage.failure(
        for: InstallerReleaseConfigurationError.unexpectedHTTPStatus(503)
      )

      XCTAssertEqual(failure.headline, "The release server returned an error")
      XCTAssertFalse(failure.plainDetail.contains("503"))
    }

    func testAnUnreadableReleaseIsExplainedPlainly() {
      let failure = PlainLanguage.failure(
        for: InstallerReleaseConfigurationError.invalidCatalogEnvelope
      )

      XCTAssertEqual(failure.headline, "The release couldn’t be verified")
    }

    func testRetryEligibleFailureIsFlaggedAndExplained() {
      let failure = PlainLanguage.failure(
        for: EngineXPCSubmissionError.recoveryAuthorizationFailed,
        retryRecoveryAvailable: true
      )

      XCTAssertTrue(failure.retryRecoveryAvailable)
      XCTAssertEqual(failure.headline, "Recovery authorization didn’t complete")
      XCTAssertNotNil(failure.remedy)
      XCTAssertNotNil(failure.technicalDetail)
    }

    func testBlockedDeviceIsFlaggedAsBlockedModel() {
      let failure = PlainLanguage.failure(
        for: ClosedEngineHelperError.unsupportedDevice("apple,j614s")
      )

      XCTAssertTrue(failure.isBlockedModel)
      XCTAssertEqual(failure.headline, PlainLanguage.blockedHeadline)
    }

    func testDigestShorteningKeepsBothEnds() {
      let digest = "sha256:" + String(repeating: "a", count: 56) + "beefcafe"

      let short = PlainLanguage.shortDigest(digest)

      XCTAssertTrue(short.hasPrefix("aaaaaaaa"))
      XCTAssertTrue(short.hasSuffix("beefcafe"))
      XCTAssertTrue(short.contains("…"))
      XCTAssertEqual(PlainLanguage.shortDigest("short"), "short")
    }

    func testByteFormattingIsWholeNumbers() {
      XCTAssertEqual(PlainLanguage.bytes(137_438_953_472), "137 GB")
      XCTAssertEqual(PlainLanguage.bytes(18_400_000), "18 MB")
      XCTAssertEqual(PlainLanguage.bytes(512), "512 bytes")
    }

    func testPlanAcknowledgementOnlyMentionsAResizeWhenMacOSShrinks() {
      XCTAssertTrue(PlainLanguage.planAcknowledgement(resizesMacOS: true).contains("resize"))
      XCTAssertFalse(PlainLanguage.planAcknowledgement(resizesMacOS: false).contains("resize"))
      XCTAssertTrue(PlainLanguage.planAcknowledgement(resizesMacOS: false).contains("backup"))
    }

    func testEncryptionCopyNamesTheCheckboxAndDefaultOnFailure() {
      XCTAssertEqual(
        PlainLanguage.encryptLinuxDiskTitle, "Encrypt the Omarchy disk")
      XCTAssertEqual(
        PlainLanguage.encryptLinuxDiskPassword,
        "The Omarchy password you create at first boot will unlock the encrypted disk after installation."
      )
      XCTAssertFalse(PlainLanguage.encryptLinuxDiskPassword.lowercased().contains("macos"))
      XCTAssertEqual(
        PlainLanguage.encryptionChoiceNotRecorded,
        "The encryption choice wasn’t saved, so Omarchy will encrypt its disk at first boot."
      )
      XCTAssertTrue(
        PlainLanguage.nextActionMessage(.enterRecovery, installConf: .notRecorded)
          .contains(PlainLanguage.encryptionChoiceNotRecorded))
      XCTAssertEqual(
        PlainLanguage.installConfWarning(.unconfirmed(encrypt: false)),
        PlainLanguage.encryptionOptOutRecorded)
      XCTAssertFalse(
        PlainLanguage.nextActionMessage(.enterRecovery, installConf: .unconfirmed(encrypt: false))
          .contains(PlainLanguage.encryptionChoiceNotRecorded))
      XCTAssertTrue(
        PlainLanguage.nextActionMessage(.enterRecovery, installConf: .unconfirmed(encrypt: false))
          .contains(PlainLanguage.encryptionOptOutRecorded))
    }

    func testCopyAuditOmitsAsahiExceptTheInstallerEngine() throws {
      let tests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let roots = [
        tests.appendingPathComponent("Sources/OmarchyInstallerUXCore"),
        tests.appendingPathComponent("Sources/OmarchyAppleInstallerApp"),
      ]
      var offenders = [String]()
      for root in roots {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
          guard file.pathExtension == "swift" else { continue }
          let text = try String(contentsOf: file, encoding: .utf8)
          for snippet in swiftStringLiterals(in: text) {
            guard snippet.localizedCaseInsensitiveContains("asahi") else { continue }
            if snippet.localizedCaseInsensitiveContains("Asahi installer") {
              continue
            }
            offenders.append("\(file.lastPathComponent): \(snippet)")
          }
        }
      }
      XCTAssertTrue(offenders.isEmpty, offenders.joined(separator: "\n"))
    }

    private func swiftStringLiterals(in text: String) -> [String] {
      var literals = [String]()
      var index = text.startIndex
      while index < text.endIndex {
        if text[index] == "\"" {
          let start = index
          index = text.index(after: index)
          var escaped = false
          while index < text.endIndex {
            let character = text[index]
            if escaped {
              escaped = false
            } else if character == "\\" {
              escaped = true
            } else if character == "\"" {
              literals.append(String(text[start...index]))
              index = text.index(after: index)
              break
            }
            index = text.index(after: index)
          }
          continue
        }
        index = text.index(after: index)
      }
      return literals
    }
  }

  private enum InstallerAppErrorStub: Error {
    case unknown
  }
#endif
