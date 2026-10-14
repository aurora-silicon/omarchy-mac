#if os(macOS)
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  final class RemovalHelperStartTests: XCTestCase {
    func testASwitchedOffHelperIsOfferedBackWhenTheBuildCanInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .disabled, canInstall: true)),
        .switchedOff)
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .disabled, canInstall: false)), .scan)
    }

    func testABlockedModelNeverSetsUpTheHelper() {
      for status in [InstallerHelperStatus.current, .outdated, .disabled, .missing] {
        for canInstall in [true, false] {
          XCTAssertEqual(
            RemovalHelperStart(
              helper: HelperDisplay(status: status, canInstall: canInstall), blockedModel: true),
            .blockedModel, "\(status) canInstall=\(canInstall)")
        }
      }
      XCTAssertTrue(PlainLanguage.removalBlockedModel.hasSuffix("No disk changes were made."))
    }

    func testABusyHelperIsLeftToFinish() {
      for canInstall in [true, false] {
        XCTAssertEqual(
          RemovalHelperStart(helper: HelperDisplay(status: .busy, canInstall: canInstall)), .busy)
      }
      XCTAssertTrue(
        PlainLanguage.removalHelperSetupMessage(for: InstallerHelperSetupError.busy).contains(
          "busy"))
    }

    func testALostReplyCountsAsRemovedOnlyWhenTheOutcomeShowsOnDisk() {
      let after: UInt64 = 500_000_000_000
      let reclaim: UInt64 = 100_000_000_000
      func loss(_ retired: Bool, _ container: UInt64?) -> RemovalConnectionLoss {
        RemovalConnectionLoss(
          helperRetired: retired, macOSContainerBytes: container, macOSBytesAfter: after,
          reclaimBytes: reclaim)
      }
      XCTAssertEqual(loss(true, after), .completed)
      // The helper's own tolerance: within 1 MiB of the planned size.
      XCTAssertEqual(loss(true, after - 1_048_576), .completed)
      XCTAssertEqual(loss(true, after - 1_048_577), .unknown)
      XCTAssertEqual(loss(true, after - reclaim / 4), .unknown, "most of the way is not done")
      XCTAssertEqual(loss(true, after + 4096), .unknown, "larger than planned is not this removal")
      // The space never came back: removal didn't finish, or never started.
      XCTAssertEqual(loss(true, after - reclaim), .unknown)
      // A helper still (or again) present leaves it unknown, whatever the disk.
      XCTAssertEqual(loss(false, after), .unknown)
      XCTAssertEqual(loss(true, nil), .unknown, "an unreadable container proves nothing")
      // A helper an installer package put in place stays. The disk alone
      // can't show it finished its records, so only the helper confirms.
      func kept(
        _ container: UInt64?, _ answer: RemovalFinalization? = nil
      ) -> RemovalConnectionLoss {
        RemovalConnectionLoss(
          helperRetired: false, helperStays: true, keptHelper: answer,
          macOSContainerBytes: container, macOSBytesAfter: after, reclaimBytes: reclaim)
      }
      XCTAssertEqual(kept(after, .finalized), .completed)
      XCTAssertEqual(kept(nil, .finalized), .completed, "the helper's records decide")
      for answer in [
        nil, RemovalFinalization.unfinished, .installRecordUncleared, .busy, .unknown,
      ] {
        // Crash windows: stopped after macOS took the space back but before
        // "complete", or before the earlier install journals were set aside.
        XCTAssertEqual(
          kept(after, answer), .spaceReclaimedUnconfirmed, "\(String(describing: answer))")
        XCTAssertEqual(kept(after - 1_048_576, answer), .spaceReclaimedUnconfirmed)
        XCTAssertEqual(kept(after - 1_048_577, answer), .unknown)
        XCTAssertEqual(kept(after - reclaim, answer), .unknown)
        XCTAssertEqual(kept(nil, answer), .unknown)
      }
      XCTAssertEqual(
        RemovalConnectionLoss(
          helperRetired: false, keptHelper: nil, macOSContainerBytes: after,
          macOSBytesAfter: after, reclaimBytes: reclaim), .unknown,
        "a helper that should retire but is still there proves nothing")
      for answer in [RemovalFinalization.unfinished, .installRecordUncleared, nil] {
        let text = PlainLanguage.removalSpaceBackUnconfirmed(freeSpace: false, finalization: answer)
        XCTAssertTrue(text.hasPrefix("Omarchy’s space is back in macOS, but"), text)
        XCTAssertFalse(text.contains("have been removed"), text)
        XCTAssertTrue(text.contains("install"), text)
      }
      XCTAssertTrue(
        PlainLanguage.removalSpaceBackUnconfirmed(freeSpace: false, finalization: .unfinished)
          .contains("Don’t start removal again"))
      XCTAssertTrue(
        PlainLanguage.removalSpaceBackUnconfirmed(freeSpace: true, finalization: nil)
          .hasPrefix("The free space is back in macOS"))
      XCTAssertTrue(
        PlainLanguage.removalCompletedWithoutReply(freeSpace: false).contains("removed itself"))
      XCTAssertFalse(
        PlainLanguage.removalCompletedWithoutReply(freeSpace: false, serviceStays: true)
          .contains("removed itself"), "a helper that stays is not said to have gone")
      XCTAssertEqual(
        RemovalConnectionLoss(
          helperRetired: true, macOSContainerBytes: after, macOSBytesAfter: after,
          reclaimBytes: 0), .unknown)
      XCTAssertTrue(
        PlainLanguage.removalCompletedWithoutReply(freeSpace: false).hasPrefix(
          "Omarchy and its data have been removed."))
      XCTAssertTrue(PlainLanguage.removalNotStarted.contains("No disk changes were made."))
    }

    func testACurrentHelperScansRightAway() {
      for canInstall in [true, false] {
        XCTAssertEqual(
          RemovalHelperStart(helper: HelperDisplay(status: .current, canInstall: canInstall)),
          .scan)
      }
    }

    func testAnOutdatedHelperIsReplacedFirstWhenTheBuildCanInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .outdated, canInstall: true)),
        .credentialsFirst)
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .outdated, canInstall: false)), .scan)
    }

    func testAMissingHelperAsksForTheAccountFirstWhenTheBuildCanInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .missing, canInstall: true)),
        .credentialsFirst)
    }

    func testAMissingHelperIsUnavailableWhenTheBuildCannotInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .missing, canInstall: false)),
        .unavailable)
    }

    func testEverySetupFailureSaysNothingChanged() {
      let errors: [any Error] = [
        EngineXPCSubmissionError.machineOwnerCredentialsRejected,
        InstallerHelperSetupError.cancelled,
        InstallerHelperSetupError.switchedOff,
        InstallerHelperSetupError.unavailable,
        InstallerHelperSetupError.notAdministrator,
        InstallerHelperSetupError.failed("launchd"),
        CocoaError(.fileNoSuchFile),
      ]
      for error in errors {
        XCTAssertTrue(
          PlainLanguage.removalHelperSetupMessage(for: error).hasSuffix(
            "No disk changes were made."), "\(error)")
      }
      XCTAssertTrue(
        PlainLanguage.removalHelperSetupMessage(
          for: EngineXPCSubmissionError.machineOwnerCredentialsRejected
        ).contains("not accepted"))
      XCTAssertTrue(
        PlainLanguage.removalHelperSetupMessage(for: InstallerHelperSetupError.switchedOff)
          .contains("Login Items"))
    }

    func testOnlyTheBuildThatCannotInstallTheHelperPointsAtThePackage() {
      XCTAssertTrue(PlainLanguage.removalServiceMissing.contains(PlainLanguage.installerPackage))
      XCTAssertFalse(
        PlainLanguage.removalServiceNotResponding.contains(PlainLanguage.installerPackage))
      XCTAssertFalse(PlainLanguage.removalCredentialsFirst.contains(PlainLanguage.installerPackage))
    }
  }
#endif
