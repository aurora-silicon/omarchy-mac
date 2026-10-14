#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  /// How the removal sheet starts. Removal needs the helper even to look for
  /// an installation, so without one the sheet asks for the administrator
  /// account first, sets the helper up with it, and only then scans. The
  /// same password then approves the removal: one prompt for the action.
  public enum RemovalHelperStart: Equatable, Sendable {
    /// A helper is registered: scan right away, as before.
    case scan
    /// No helper, or one from another build, and this build can install its
    /// own: ask for the account first.
    case credentialsFirst
    /// No helper, and this build cannot install one.
    case unavailable
    /// The person switched the helper off in Login Items: ask for the
    /// account first and offer to turn it back on with it.
    case switchedOff
    /// This Mac model is refused outright; nothing privileged is set up.
    case blockedModel
    /// The helper is busy with another job; try again later.
    case busy

    /// - Parameter helper: the status from asking the helper itself, so a
    ///   switched-off helper shows as `.disabled`.
    /// - Parameter blockedModel: this Mac is a model the installer refuses;
    ///   it wins over every helper state, so no helper is ever installed.
    public init(helper: HelperDisplay, blockedModel: Bool = false) {
      if blockedModel {
        self = .blockedModel
        return
      }
      switch helper.status {
      case .current:
        self = .scan
      case .outdated:
        // Replace it first: a helper from another build may refuse this app.
        self = helper.canInstall ? .credentialsFirst : .scan
      case .disabled:
        self = helper.canInstall ? .switchedOff : .scan
      case .busy:
        self = .busy
      case .missing:
        self = helper.canInstall ? .credentialsFirst : .unavailable
      }
    }
  }

  /// What a lost connection after a submitted removal means. It counts as
  /// done only when the outcome is proven: a helper the app installed itself
  /// has retired completely (it deletes its job file, binary and state only
  /// after a completed removal) and the macOS container has reached its
  /// planned size after removal, by the helper's own completion tolerance; or
  /// a helper an installer package put in place, which stays after a
  /// removal, confirms from its records that the removal completed and set
  /// aside the earlier installation's journals. The container size alone
  /// can't show that, so with a kept helper that doesn't confirm it, a
  /// reclaimed container means only that macOS has its space back. Anything
  /// less stays unknown, including a helper briefly absent while another
  /// build reinstalls it.
  public enum RemovalConnectionLoss: Equatable, Sendable {
    case completed
    /// macOS has its space back, but the kept helper didn't confirm the
    /// removal finished; installing stays blocked until its records do.
    case spaceReclaimedUnconfirmed
    case unknown

    /// - Parameters:
    ///   - helperRetired: the helper's job file, binary and state directory
    ///     are all gone, in two looks a moment apart.
    ///   - helperStays: the registered helper is one an installer package put
    ///     in place, which never retires.
    ///   - keptHelper: what that helper's records say about this removal, nil
    ///     when it wasn't asked or didn't answer.
    ///   - macOSContainerBytes: the macOS APFS container's size now, if known.
    ///   - macOSBytesAfter: its size once removal completes, from the plan.
    ///   - reclaimBytes: the space removal returns to it, from the plan.
    public init(
      helperRetired: Bool, helperStays: Bool = false, keptHelper: RemovalFinalization? = nil,
      macOSContainerBytes: UInt64?, macOSBytesAfter: UInt64, reclaimBytes: UInt64
    ) {
      // The helper's own test that macOS took the space back: within 1 MiB
      // of its planned size, and not beyond it.
      let tolerance: UInt64 = 1_048_576
      var reclaimed = false
      if let macOSContainerBytes, reclaimBytes > 0, macOSBytesAfter >= reclaimBytes {
        reclaimed =
          macOSContainerBytes <= macOSBytesAfter
          && macOSBytesAfter - macOSContainerBytes <= tolerance
      }
      if helperRetired {
        self = reclaimed ? .completed : .unknown
      } else if keptHelper == .finalized {
        // Only a helper that stays answers this: one that retires does so
        // before its reply leaves, and from then on answers nothing.
        self = .completed
      } else if helperStays, reclaimed {
        self = .spaceReclaimedUnconfirmed
      } else {
        self = .unknown
      }
    }
  }

  extension PlainLanguage {
    /// Shown when the reply was lost but the disk, with the helper's
    /// retirement or a helper that stays by design, proves the removal
    /// completed.
    /// - Parameter serviceStays: the helper an installer package put in place
    ///   is still registered, as it stays after a removal.
    public static func removalCompletedWithoutReply(
      freeSpace: Bool, serviceStays: Bool = false
    ) -> String {
      let result =
        freeSpace
        ? "The free space is now part of macOS."
        : "Omarchy and its data have been removed. The freed space is now part of macOS."
      return result
        + (serviceStays
          ? " The removal service finished before this window heard back, as can happen if the Mac sleeps."
          : " The removal service finished and removed itself before this window heard back, as can happen if the Mac sleeps.")
    }

    /// Shown when the reply was lost, macOS has its space back, but the
    /// helper that stays after a removal didn't confirm the removal finished.
    public static func removalSpaceBackUnconfirmed(
      freeSpace: Bool, finalization: RemovalFinalization?
    ) -> String {
      let result =
        (freeSpace ? "The free space is back in macOS" : "Omarchy’s space is back in macOS")
        + ", but the removal service didn’t confirm that the removal finished before this window heard back, as can happen if the Mac sleeps."
      switch finalization {
      case .installRecordUncleared:
        return result
          + " It couldn’t yet set aside its record of the earlier installation. It tries again before the next installation and won’t install until that works."
      case .unfinished:
        return result
          + " Its removal record stops before the end, so the installer won’t install again until that record is checked. Don’t start removal again; keep the record in \(InstallerProductIdentity.helperWorkingDirectory) for support."
      default:
        return result
          + " The installer checks its removal record before the next installation and won’t install until it shows the removal finished."
      }
    }

    public static let removalCredentialsFirst =
      "To look for Omarchy on this Mac, enter your macOS administrator account. It sets up the removal service and approves the removal you’ll review next. macOS will show a notice that \(windowTitle) added a background item."
    public static let removalContinue = "Continue"
    public static let removalNotStarted =
      "The removal service didn’t answer, so removal didn’t start. No disk changes were made. Close this window and try again."
    public static let removalServiceBusy =
      "The removal service is busy with another request. Close this window and try again when it finishes. If it stays busy, an installation or removal may still be running, perhaps in another user’s session: let it finish, and don’t restart or shut down this Mac while it runs. No disk changes were made."
    public static let removalBlockedModel =
      "Removal is not supported on this Mac model. No disk changes were made."
    public static let removalSwitchedOff =
      "The removal service is switched off in Login Items, and it’s needed to look for Omarchy. Enter your macOS administrator account and choose Turn On & Continue to switch it back on, or switch it on in Login Items yourself and reopen this window."
    public static let removalTurnOnAndContinue = "Turn On & Continue"
    /// Builds that cannot install the helper, when the package has not.
    public static let removalServiceMissing =
      "The removal service isn’t available. Run the downloaded \(installerPackage) again, then try again. No disk changes were made."
    public static let removalServiceNotResponding =
      "The removal service didn’t respond. Close this window and try again. No disk changes were made."

    /// What the removal sheet says when setting up the helper failed.
    public static func removalHelperSetupMessage(for error: any Error) -> String {
      if let submission = error as? EngineXPCSubmissionError,
        submission == .machineOwnerCredentialsRejected
      {
        return
          "The macOS account or password was not accepted. Use a macOS administrator account. No disk changes were made."
      }
      switch error as? InstallerHelperSetupError {
      case .cancelled:
        return
          "The removal service wasn’t set up. Try again, and approve the macOS password prompt if it appears. No disk changes were made."
      case .switchedOff:
        return
          "The removal service is switched off. In System Settings, open General → Login Items & Extensions, switch it on under Allow in the Background, then try again. No disk changes were made."
      case .unavailable:
        return removalServiceMissing
      case .busy:
        return removalServiceBusy
      case .notAdministrator:
        return
          "This account isn’t a macOS administrator, and setting up the removal service needs one. Use an administrator account. No disk changes were made."
      case .failed, nil:
        return "The removal service couldn’t be set up. Try again. No disk changes were made."
      }
    }
  }
#endif
