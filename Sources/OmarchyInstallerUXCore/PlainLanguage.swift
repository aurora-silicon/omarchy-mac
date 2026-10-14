#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  /// Every user-visible string in the installer. Screens read from here so the
  /// wording can be reviewed in one place and unit-tested for completeness.
  public enum PlainLanguage {
    // MARK: Chrome

    public static let windowTitle = InstallerProductIdentity.appName
    /// The downloaded package people run again to repair the installation
    /// service, named as it is saved so it can't be mistaken for this app.
    public static let installerPackage = InstallerProductIdentity.appName + ".pkg"

    // MARK: Screen A — Check

    public static let checkSubheadline =
      "Omarchy installs next to macOS. You can select either one by holding the power button when the Mac starts."
    public static let checkContinue = "Continue"
    public static let checkAgain = "Check again"
    public static let inspectingHeadline = "Checking this Mac…"
    public static let inspectingSubheadline =
      "Checking the Mac model, macOS version, power, FileVault, and free disk space."

    // MARK: Screen A2 — Existing install

    public static let existingInstallHeadline = "Omarchy is already installed"
    public static let closeInstaller = "Close"

    // MARK: Screen B — Plan

    public static func allocationNotice(requestedBytes: UInt64, actualBytes: UInt64) -> String? {
      let formatter = DiskSizeInput()
      let requested = formatter.display(requestedBytes)
      let actual = formatter.display(actualBytes)
      // Disk alignment changes bytes without changing the whole GB the user chose.
      guard requested != actual else { return nil }
      return
        "Space for Omarchy changed from \(requested) GB to \(actual) GB. Review the updated size before installing."
    }

    public static let replanning = "Checking the new size…"
    /// A free-space plan leaves macOS its current size, so only a plan that
    /// shrinks macOS asks to approve a resize.
    public static func planAcknowledgement(resizesMacOS: Bool) -> String {
      resizesMacOS
        ? "I have a current backup and approve the disk resize above."
        : "I have a current backup and approve the disk layout above."
    }
    public static let planInstall = "Install"
    public static let downloadingPackagesTitle = "Downloading Omarchy"
    public static let encryptLinuxDiskTitle = "Encrypt the Omarchy disk"
    public static let encryptLinuxDiskPassword =
      "The Omarchy password you create at first boot will unlock the encrypted disk after installation."
    public static let encryptLinuxDiskNoRecovery =
      "There is no separate recovery key, so keep the password somewhere safe."
    public static let encryptionChoiceNotRecorded =
      "The encryption choice wasn’t saved, so Omarchy will encrypt its disk at first boot."
    public static let encryptionOptOutRecorded =
      "Disk encryption is off, and that choice was saved."
    public static let encryptionChoiceUnconfirmed =
      "Encryption was recorded, but the installer could not confirm the disk was unmounted."
    public static let prefetchWaitingForNetwork = "Waiting for Wi-Fi or Ethernet…"
    public static let prefetchPaused = "Download paused"
    public static let prefetchVerifying = "Verifying the download…"
    public static let prefetchFailed = "The download failed or didn’t pass verification."
    public static let prefetchRetry = "Try again"

    public static func prefetchTitle(for state: PayloadPrefetchState) -> String {
      switch state {
      case .idle, .downloading:
        downloadingPackagesTitle
      case .waitingForUnmeteredNetwork:
        prefetchWaitingForNetwork
      case .paused:
        prefetchPaused
      case .verifying:
        prefetchVerifying
      case .verified:
        downloadingPackagesTitle
      case .failed:
        prefetchFailed
      case .cancelled:
        prefetchPaused
      }
    }

    public static func preparingStageTitle(
      _ stage: AssetProgressUpdate.Stage
    ) -> String {
      switch stage {
      case .fetchingCatalog: "Checking the release signature…"
      case .downloading: "Downloading Omarchy…"
      case .inspectingEngine: "Checking disk compatibility…"
      case .planning: "Planning the disk layout…"
      }
    }

    // MARK: Screen C — Authorize

    public static let authorizeTitle =
      "Authorize installation"
    public static let authorizeRetryTitle = "Authorize the Recovery step"
    public static let authorizeUsernameLabel = "macOS user"
    public static let authorizeChecking = "Checking your macOS account…"
    public static let authorizeStillWorking =
      "This can take a few minutes. Once your account is confirmed, the installer prepares Omarchy’s files."
    public static let authorizePasswordLabel = "macOS password"
    public static let authorizeCancel = "Cancel"
    public static let authorizeRetryAction = "Authorize"
    public static let authorizeRejected =
      "The user name or password was incorrect."
    /// Shown on the sheet when authorizing will install the helper.
    public static let authorizeBackgroundItemNotice =
      "macOS will show a notice that \(windowTitle) added a background item. That’s the installation service; it’s removed along with Omarchy."
    public static let authorizeHelperCancelled =
      "The installation service wasn’t set up, so nothing was changed. Try again, and approve the macOS password prompt if it appears."
    public static let authorizeHelperSwitchedOff =
      "The installation service is switched off in Login Items. Turn it back on here with your password, or switch it on in Login Items and try again."
    /// Shown on the sheet when the person switched the helper off.
    public static let authorizeHelperSwitchedOffNotice =
      "You switched the installation service off in Login Items, and \(windowTitle) needs it to change your disk. Authorizing turns it back on with the password you enter here; it’s removed along with Omarchy. You can switch it on in Login Items yourself instead."
    public static let authorizeTurnOnAndInstall = "Turn On & Install"
    public static let authorizeTurnOnAndRetry = "Turn On & Authorize"
    public static let openLoginItems = "Open Login Items"
    /// System Settings → General → Login Items & Extensions.
    public static let loginItemsSettingsURL = URL(
      string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    public static let helperBeingReplacedHeadline = "The installation service is being updated"
    public static let helperBeingReplacedDetail =
      "Another copy of the installer is replacing the installation service, so this request didn't start and nothing was changed. Try again in a moment."
    public static let earlierRemovalUnfinishedHeadline = "An earlier removal didn’t finish"
    public static let earlierRemovalUnfinishedDetail =
      "The installer’s record of an earlier Omarchy removal stops before it finished, so the disk may not be in the layout the installer expects. Installation didn’t start and nothing was changed."
    public static let earlierRemovalUnfinishedRemedy =
      "Check the disk layout in Disk Utility, and keep the removal record in \(InstallerProductIdentity.helperWorkingDirectory) for support. The installer won’t install until that record is resolved."
    public static let earlierInstallRecordUnclearedHeadline =
      "The installer couldn’t clear an earlier installation’s record"
    public static let earlierInstallRecordUnclearedDetail =
      "After the last removal, the installer couldn’t set aside its record of the installation it removed. Installing at the same size could reuse that record and skip installing, so installation didn’t start and nothing was changed."
    public static let earlierInstallRecordUnclearedRemedy =
      "Try again: each attempt tries to set the record aside first. If this keeps happening, keep the records in \(InstallerProductIdentity.helperWorkingDirectory) for support."
    public static let helperRetiringHeadline = "The installation service was just removed"
    public static let helperRetiringDetail =
      "Omarchy's removal finished and its installation service is removing itself. Nothing was changed. Try again in a moment; the app sets the service up again with your password."
    public static let authorizeNotAdministrator =
      "This account isn’t a macOS administrator, and setting up the installation service needs one. Use an administrator account."
    public static let authorizeHelperBusy =
      "The installation service is busy with another request, so nothing was changed. Try again when it finishes. If it stays busy, an installation or removal may still be running, perhaps in another user’s session: let it finish, and don’t restart or shut down this Mac while it runs."
    public static let authorizeHelperFailed =
      "The installation service couldn’t be set up, so nothing was changed. Try again."

    // MARK: Confirmation dialogs (preserved verbatim)

    public static let recoveryRetryConfirmationTitle =
      "Retry the Recovery authorization step?"
    public static let recoveryRetryConfirmationBody =
      "Before retrying Apple’s startup authorization, the installer rechecks the approved plan, the installation files, the disk location, and the last completed step. The retry can’t resize the disk, change partitions, or rewrite the installed system."
    public static let recoveryRetryConfirmationAction =
      "Retry Recovery authorization"
    public static let cancel = "Cancel"

    // MARK: Screen D — Install

    public static let installWarning =
      "Keep this Mac open and plugged in."
    public static let installDegraded =
      "Live progress isn’t available. The installer will check the installation record when complete."
    public static let installVerifyingOwner = "Checking your macOS account…"
    public static let installStageLabels = [
      "Preparing disk space", "Installing boot files",
      "Preparing final setup",
    ]

    public static func installPhaseTitle(forPhase phase: String?) -> String {
      switch phase {
      case "preflight": "Checking the disk…"
      case "existing_removal": "Removing the previous Omarchy installation…"
      case "apfs_preparation": "Preparing disk space…"
      case "stub_and_esp": "Writing boot files…"
      case "awaiting_recovery": "Preparing final setup…"
      case "boot_policy": "Authorizing startup…"
      case "media_handoff": "Preparing installation media…"
      case "omarchy_install": "Installing Omarchy…"
      default: installVerifyingOwner
      }
    }

    public static func installPhaseTitle(forEvent event: String?) -> String? {
      switch event {
      case "existing_removal_started": "Removing the previous Omarchy installation…"
      case "apfs_preparation_started": "Preparing disk space…"
      case "stub_and_esp_started": "Writing boot files…"
      case "recovery_handoff_started": "Preparing final setup…"
      default: nil
      }
    }

    public static func checkpointSummary(_ identifier: String) -> String {
      switch identifier {
      case "existing-install-removed": "Previous Omarchy installation removed"
      case "apfs-target-prepared": "Disk space reserved for Omarchy"
      case "stub-and-esp-installed": "Boot files written"
      case "recovery-handoff-prepared": "Ready to finish setup"
      default: "Additional installation activity (\(identifier))"
      }
    }

    public static func eventSummary(_ name: String) -> String {
      switch name {
      case "existing_removal_started": "Started removing the previous Omarchy installation"
      case "apfs_preparation_started": "Started preparing disk space"
      case "stub_and_esp_started": "Started writing boot files"
      case "recovery_handoff_started": "Started preparing final setup"
      default: "Additional installation activity (\(name))"
      }
    }

    // MARK: Screen E — Recovery

    public static let recoveryHeadline = "Finish setup"
    public static let recoveryShutDown = "Shut down"
    public static let shutdownConfirmationTitle = "Shut down this Mac now?"
    public static let shutdownConfirmationBody =
      "Save your work first. When this Mac is off, press and hold the power button until “Loading startup options” appears. Choose Omarchy → Finish Installation, then sign in with your macOS account."
    public static let shutdownConfirmationAction = "Shut down"
    public static let mediaHeadline = "Connect the installation media"

    /// Numbered plain-language steps for the signed `requiredHumanSteps`
    /// tokens. Unknown tokens are surfaced rather than dropped.
    public static func recoverySteps(
      for requiredHumanSteps: [String]
    ) -> [RecoveryStep] {
      var steps = [RecoveryStep]()
      var number = 1
      func append(_ title: String, _ detail: String) {
        steps.append(RecoveryStep(number: number, title: title, detail: detail))
        number += 1
      }
      func enterRecovery() {
        append("Shut down this Mac", "Save your work first.")
        append(
          "Hold the power button",
          "When this Mac is off, press and hold the power button until “Loading startup options” appears."
        )
      }
      func authenticate() {
        append(
          "Finish installation",
          "Choose Omarchy → Finish Installation, then sign in with your macOS account.")
      }
      for token in requiredHumanSteps {
        switch token {
        case "enterOneTrueRecovery":
          enterRecovery()
        case "authenticateMachineOwner":
          authenticate()
        default:
          append(
            "Unsupported Recovery instruction: \(token)",
            "Save the installation record and get support before continuing.")
        }
      }
      if steps.isEmpty {
        enterRecovery()
        authenticate()
      }
      return steps
    }

    // MARK: Screen F — Boot / completion

    public static let doneHeadline = "Omarchy is installed"
    public static let startOver = "Start over"
    public static let downloadInstaller = "Download the installer"
    public static let rcBadge = "Release candidate"
    public static let channelMenuTitle = "Release channel"
    public static let channelStable = "Stable"
    public static let channelRC = "Release candidate"
    public static let channelEdge = "Edge"
    public static let channelNoMacRelease = "No Mac release yet"
    public static let channelModelUnavailable = "Not available for this Mac"
    public static let channelUnreachable = "Couldn’t load"
    public static let channelUnverified = "Couldn’t verify"
    public static let channelMenuCheckAgain = "Check Channels Again"

    public static func badge(for channel: ReleaseChannel) -> String {
      switch channel {
      case .stable: channelStable
      case .rc: rcBadge
      case .edge: channelEdge
      }
    }

    /// A channel menu item: the channel's name, then what its verified
    /// catalog offers this Mac when that is not simply "available".
    public static func channelMenuItem(
      _ channel: ReleaseChannel,
      availability: ReleaseChannelAvailability?
    ) -> String {
      let name = badge(for: channel)
      let state: String? =
        switch availability {
        case .none, .available: nil
        case .noRelease: channelNoMacRelease
        case .modelUnavailable: channelModelUnavailable
        case .checkFailed(.network): channelUnreachable
        case .checkFailed(.verification): channelUnverified
        }
      guard let state else { return name }
      return "\(name) — \(state)"
    }

    /// Whether the channel menu lets this item be chosen. The channel in use
    /// always stays chosen; one not yet checked, or whose check failed, can
    /// be chosen to try it.
    public static func channelMenuItemEnabled(
      _ channel: ReleaseChannel,
      selected: ReleaseChannel?,
      availability: ReleaseChannelAvailability?
    ) -> Bool {
      channel == selected || availability?.isSelectable ?? true
    }

    public static var doneVerifiedRows: [PlanFactRow] {
      doneVerifiedRows(profile: .current)
    }

    public static func doneVerifiedRows(profile: InstallerBuildProfile) -> [PlanFactRow] {
      [
        PlanFactRow(label: "Startup sequence", value: profile.startupSequence),
        PlanFactRow(
          label: "File verification",
          value: "Release verified, files written"
        ),
      ]
    }

    public static func installConfWarning(_ installConf: InstallConfHandoff) -> String? {
      switch installConf {
      case .recorded:
        nil
      case .notRecorded:
        encryptionChoiceNotRecorded
      case .unconfirmed(let encrypt):
        encrypt ? encryptionChoiceUnconfirmed : encryptionOptOutRecorded
      }
    }

    public static func nextActionMessage(
      _ action: InstallerNextAction,
      installConf: InstallConfHandoff = .recorded
    ) -> String {
      let base: String
      switch action {
      case .continueInstallation:
        base = "Your approved plan was accepted. Installation is continuing."
      case .enterRecovery:
        base =
          "Omarchy’s files are in place. Finish setup at startup so this Mac can start Omarchy."
      case .attachInstallationMedia:
        base = "Preparation is complete. Connect the verified installation media to continue."
      case .verifyInstalledSystem:
        base = "Installation is complete. Start Omarchy and check that it works."
      case .manualRecovery:
        base = "Installation needs manual recovery before it can continue."
      }
      if let warning = installConfWarning(installConf) {
        return base + " " + warning
      }
      return base
    }

    // MARK: Blocked

    public static let blockedHeadline = "This Mac isn’t supported yet"
    public static let blockedSubheadline =
      "This Mac model has not been approved for this release."
    public static let blockedExplainer =
      "Each Mac model is tested on real hardware before a signed release includes it. A catalog update can withdraw support, but adding a model needs a new release."
    public static let blockedBadge = "Not supported"
    public static let notReadyHeadline = "This Mac isn’t ready yet"
    public static let notReadyDetail =
      "The installer couldn’t confirm that this Mac meets the installation requirements."
    public static let supportedBadge = "Supported"

    /// "MacBook Pro 14-inch (M3, 2023) · Mac15,3 · apple,j504", leaving out
    /// what isn't known.
    public static func macDescription(
      deviceIdentifier: String,
      modelIdentifier: String? = nil
    ) -> String {
      [MacModelNames.name(for: deviceIdentifier), modelIdentifier, deviceIdentifier]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    /// The helper refused to install because of an earlier removal's record.
    static func earlierRemovalGate(unfinished: Bool, technicalDetail: String) -> FailureDisplay {
      unfinished
        ? FailureDisplay(
          headline: earlierRemovalUnfinishedHeadline,
          plainDetail: earlierRemovalUnfinishedDetail,
          technicalDetail: technicalDetail,
          remedy: earlierRemovalUnfinishedRemedy)
        : FailureDisplay(
          headline: earlierInstallRecordUnclearedHeadline,
          plainDetail: earlierInstallRecordUnclearedDetail,
          technicalDetail: technicalDetail,
          remedy: earlierInstallRecordUnclearedRemedy)
    }

    /// The blocked-model card: names this Mac and, when the signed catalog
    /// could be read, the model families this release supports.
    public static func unsupportedModel(
      deviceIdentifier: String,
      modelIdentifier: String? = nil,
      supportedDeviceIdentifiers: [String]? = nil,
      technicalDetail: String? = nil
    ) -> FailureDisplay {
      let mac = macDescription(
        deviceIdentifier: deviceIdentifier, modelIdentifier: modelIdentifier)
      let remedy: String
      if let supported = supportedDeviceIdentifiers,
        let summary = MacModelNames.supportedFamiliesSummary(supported)
      {
        remedy =
          "This release supports these Macs (\(supported.count) models): \(summary). "
          + blockedExplainer
      } else {
        remedy = blockedExplainer
      }
      return FailureDisplay(
        headline: blockedHeadline,
        plainDetail: "This Mac (\(mac)) isn’t included in this release.",
        technicalDetail: technicalDetail,
        remedy: remedy,
        isBlockedModel: true
      )
    }

    /// A verified, signed catalog that admits no Mac: the channel exists but
    /// has nothing to install yet. Not a network or verification problem.
    public static func noMacRelease(technicalDetail: String? = nil) -> FailureDisplay {
      FailureDisplay(
        headline: "No Mac release on this channel yet",
        plainDetail:
          "This release channel is verified but doesn’t offer Omarchy for any Mac yet. No installation files were downloaded and the disk has not been changed.",
        technicalDetail: technicalDetail,
        remedy: "Choose another channel from the Release channel menu, or check again later."
      )
    }

    public static func unsupportedModel(_ model: UnsupportedModelDisplay) -> FailureDisplay {
      unsupportedModel(
        deviceIdentifier: model.deviceIdentifier,
        modelIdentifier: model.modelIdentifier,
        supportedDeviceIdentifiers: model.supportedDeviceIdentifiers
      )
    }

    // MARK: Engine failures

    public static let replanAction = "Check available space"
    public static let engineDiagnosticsLocation =
      "Choose Copy error details to keep them. A copy is usually saved in ~/Library/Logs/\(EngineFailureUserLog.directoryName)."

    /// Plain wording for a typed engine failure. The disk-unchanged sentence
    /// appears only when the helper proved it from the installation journal.
    public static func engineFailure(
      _ notice: EngineFailureNotice,
      technicalDetail: String
    ) -> FailureDisplay {
      let unchanged = notice.diskUnchanged
      let diskState =
        unchanged
        ? "No disk changes were made."
        : "The installer couldn’t confirm whether disk changes started."
      switch notice.reason {
      case .approvedSpaceChanged:
        return FailureDisplay(
          headline: "The space available for Omarchy changed",
          plainDetail:
            "The size you approved no longer fits the space this Mac can provide now, so the installer stopped before using it. \(diskState)",
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Choose \(replanAction) to prepare a new plan with the space available now, then review and approve it."
            : "Save the error details and check the verified installation record before trying again. \(engineDiagnosticsLocation)",
          replanAvailable: unchanged
        )
      case .diskLayoutChanged:
        return FailureDisplay(
          headline: "The disk changed after you approved the plan",
          plainDetail:
            "The disk layout no longer matches the approved plan, so the installer stopped. \(diskState)",
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Choose \(replanAction) to prepare a new plan for the disk as it is now, then review and approve it."
            : "Save the error details and check the verified installation record before trying again. \(engineDiagnosticsLocation)",
          replanAvailable: unchanged
        )
      case .preparedResumeMismatch:
        return FailureDisplay(
          headline: "The prepared installation no longer matches its saved checkpoint",
          plainDetail: unchanged
            ? "The current disk no longer matches the saved checkpoint. No disk changes were made."
            : "The installation already prepared disk space for Omarchy. That disk space no longer matches the saved checkpoint. No further installation step was started by this resume attempt; earlier disk changes are not undone.",
          technicalDetail: technicalDetail,
          remedy:
            "Keep the installation journal and copy the error details. Review the saved checkpoints to see whether file installation also completed. Restore the expected disk state or get help reconciling it before resuming; do not delete the journal or start a fresh install over it. \(engineDiagnosticsLocation)"
        )
      case .deviceUnsupported:
        return FailureDisplay(
          headline: blockedHeadline,
          plainDetail: "The installer engine doesn’t support this Mac model. \(diskState)",
          technicalDetail: technicalDetail,
          remedy: blockedExplainer,
          isBlockedModel: true
        )
      case .planIntegrity:
        return FailureDisplay(
          headline: "The installation plan failed a safety check",
          plainDetail:
            "The installer engine refused the plan because it didn’t match the verified release. \(diskState)",
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Choose Check again to inspect this Mac and prepare a new plan. \(engineDiagnosticsLocation)"
            : "Save the error details and check the verified installation record before trying again. \(engineDiagnosticsLocation)"
        )
      case .unclassified:
        return FailureDisplay(
          headline: "The installer engine stopped with an error",
          plainDetail: diskState,
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Choose Check again to start over. \(engineDiagnosticsLocation)"
            : "Save the error details and check the verified installation record before trying again. \(engineDiagnosticsLocation)"
        )
      }
    }

    // MARK: Errors

    public static let retry = "Try again"

    /// Shown only by builds that cannot install the helper themselves, when
    /// the installer package has not put it in place.
    public static let helperNotInstalled =
      "The installation service is missing. Run the downloaded \(installerPackage) again, then reopen this app."

    public static let engineUnavailable =
      "This build is missing the required validation engine. Installation is unavailable."
    public static let engineIdentityMismatch =
      "The validation engine failed an identity check. Installation is unavailable."
    public static let releaseResourcesUnavailable =
      "This build is missing a verified production release identity. Installation is unavailable."
    public static let planChangedBeforeApproval =
      "The installation plan changed. Prepare and review the new plan before continuing."
    public static let approvalUnavailable =
      "The approved plan or installation service is no longer available. Prepare and review the plan again."
    public static let retryCheckpointUnavailable =
      "The verified checkpoint needed to retry Recovery authorization is unavailable. Installation remains stopped."
    public static let inspectionRequired =
      "Complete the Mac and disk checks before continuing."

    /// Maps a thrown error to the four-part failure card the screens render.
    /// `technicalDetail` always preserves `String(describing:)` so nothing is
    /// lost behind the plain-language headline.
    public static func failure(
      for error: any Error,
      retryRecoveryAvailable: Bool = false
    ) -> FailureDisplay {
      let technical = String(describing: error)

      if let preflight = error as? InstallerPreSubmissionFailure,
        let submission = preflight.underlying as? EngineXPCSubmissionError,
        submission == .helperUnresponsive || submission == .connectionFailed
      {
        return FailureDisplay(
          headline: "The installation service isn’t responding",
          plainDetail: retryRecoveryAvailable
            ? "No new installation request was sent. Your verified installation checkpoint is preserved."
            : "The app couldn’t get a response from the installation service. Installation has not started.",
          technicalDetail: String(describing: preflight.underlying),
          remedy: "Run the downloaded \(installerPackage) again, then reopen this app.",
          retryRecoveryAvailable: retryRecoveryAvailable
        )
      }

      if retryRecoveryAvailable {
        return FailureDisplay(
          headline: "Recovery authorization didn’t complete",
          plainDetail:
            "Disk preparation and file installation were verified. Retry the Recovery authorization step.",
          technicalDetail: technical,
          remedy:
            "Enter the authorized macOS account password again. Only the Recovery authorization step will be retried.",
          retryRecoveryAvailable: true
        )
      }

      if let preflight = error as? InstallerPreSubmissionFailure {
        return FailureDisplay(
          headline: "Installation couldn’t start",
          plainDetail:
            "This attempt stopped before an installation request was sent. It made no disk changes.",
          technicalDetail: String(describing: preflight.underlying),
          remedy:
            "Check the error details, then choose Check again to prepare and review a fresh plan."
        )
      }

      if let submission = error as? EngineXPCSubmissionError {
        switch submission {
        case .machineOwnerCredentialsRejected:
          return FailureDisplay(
            headline: authorizeRejected,
            plainDetail:
              "Your credentials were rejected before this request could change the disk.",
            technicalDetail: technical,
            remedy:
              "Enter the account name and password of a macOS account authorized to install on this Mac."
          )
        case .recoveryAuthorizationFailed:
          return FailureDisplay(
            headline: "Recovery authorization didn’t complete",
            plainDetail:
              "Disk preparation and file installation were verified. Recovery authorization is still required.",
            technicalDetail: technical,
            remedy: "Retry only the Recovery authorization step."
          )
        case .helperUnresponsive:
          return FailureDisplay(
            headline: "The installation service isn’t responding",
            plainDetail:
              "The app couldn’t get a response from the installation service. Installation has not started.",
            technicalDetail: technical,
            remedy: "Quit \(windowTitle), open it again, and try once more."
          )
        case .connectionFailed:
          return FailureDisplay(
            headline: "Connection to the installation service was lost",
            plainDetail:
              "Disk changes may have started. The app cannot yet confirm the installation result.",
            technicalDetail: technical,
            remedy:
              "Keep your Mac connected to power. Save the error details and check the verified installation record before trying again."
          )
        case .engineFailed(let notice):
          return engineFailure(notice, technicalDetail: technical)
        case .helperRejected(let domain, let code):
          let replaced = ClosedEngineHelperError.beingReplaced as NSError
          if domain == replaced.domain, code == replaced.code {
            return FailureDisplay(
              headline: PlainLanguage.helperBeingReplacedHeadline,
              plainDetail: PlainLanguage.helperBeingReplacedDetail,
              technicalDetail: technical
            )
          }
          let retiring = ClosedEngineHelperError.retiring as NSError
          if domain == retiring.domain, code == retiring.code {
            return FailureDisplay(
              headline: PlainLanguage.helperRetiringHeadline,
              plainDetail: PlainLanguage.helperRetiringDetail,
              technicalDetail: technical
            )
          }
          for unfinished in [true, false] {
            let gate =
              (unfinished
              ? ClosedEngineHelperError.earlierRemovalUnfinished
              : .earlierInstallRecordUncleared) as NSError
            if domain == gate.domain, code == gate.code {
              return earlierRemovalGate(unfinished: unfinished, technicalDetail: technical)
            }
          }
          let busy = ClosedEngineHelperError.busy as NSError
          if domain == busy.domain, code == busy.code {
            return FailureDisplay(
              headline: "An installation may already be running",
              plainDetail:
                "Keep your Mac powered on. An installation may still be running; check its installation record before starting another attempt.",
              technicalDetail: technical
            )
          }
          return FailureDisplay(
            headline: "The installation service couldn’t complete the request",
            plainDetail:
              "The service returned an error. The app cannot confirm whether disk changes have started.",
            technicalDetail: technical,
            remedy:
              "Save the error details and check the verified installation record before trying again."
          )
        default:
          return FailureDisplay(
            headline: "The installation result is unknown",
            plainDetail:
              "The installation service did not return a verified result. Disk changes may have started.",
            technicalDetail: technical,
            remedy:
              "Save the error details and check the verified installation record before trying again."
          )
        }
      }

      if let helper = error as? ClosedEngineHelperError {
        switch helper {
        case .beingReplaced:
          return FailureDisplay(
            headline: PlainLanguage.helperBeingReplacedHeadline,
            plainDetail: PlainLanguage.helperBeingReplacedDetail,
            technicalDetail: technical
          )
        case .retiring:
          return FailureDisplay(
            headline: PlainLanguage.helperRetiringHeadline,
            plainDetail: PlainLanguage.helperRetiringDetail,
            technicalDetail: technical
          )
        case .busy:
          return FailureDisplay(
            headline: "An installation may already be running",
            plainDetail:
              "Keep your Mac powered on. Check the existing installation before trying again.",
            technicalDetail: technical
          )
        case .invalidMachineOwnerCredentials:
          return FailureDisplay(
            headline: authorizeRejected,
            plainDetail: "This request did not change the disk.",
            technicalDetail: technical
          )
        case .unsupportedDevice(let identifier):
          return unsupportedModel(deviceIdentifier: identifier, technicalDetail: technical)
        case .earlierRemovalUnfinished:
          return earlierRemovalGate(unfinished: true, technicalDetail: technical)
        case .earlierInstallRecordUncleared:
          return earlierRemovalGate(unfinished: false, technicalDetail: technical)
        default:
          return FailureDisplay(
            headline: "The installation service reported an error",
            plainDetail:
              "Check the last verified installation step to see what completed.",
            technicalDetail: technical,
            remedy:
              "Save the error details and check the verified installation record before trying again."
          )
        }
      }

      if let allocation = error as? InstallerAllocationRecommendationError {
        switch allocation {
        case .snapshotConstrained(let constraint):
          let detail =
            constraint == .timeMachine
            ? "macOS reports that a local Time Machine snapshot limits how far the APFS container can shrink."
            : "macOS reports that an APFS snapshot limits how far the container can shrink. It was not identified as a local Time Machine snapshot."
          let remedy =
            constraint == .timeMachine
            ? "Back up your Mac first. Local snapshots are restore points on the startup disk, separate from backups on an external disk. You can wait for automatic cleanup or follow Apple’s local-snapshot guidance. Removing local snapshots removes those local restore points. Restore your automatic backup schedule afterward, then choose Check again."
            : "Back up your Mac first. A system, update, or other snapshot may be involved. Let any pending macOS update finish, then restart and choose Check again. Do not manually delete system or update snapshots. Apple’s local-snapshot guidance applies to Time Machine snapshots only."
          return FailureDisplay(
            headline: "Snapshots limit the space available for installation",
            plainDetail:
              "\(detail) Free space shown in macOS is not necessarily space that can be released for a new partition. The disk has not been changed.",
            technicalDetail: technical,
            remedy:
              "\(remedy) Snapshot cleanup may still leave too little space to meet the installation and macOS reserve requirements. The installer does not delete snapshots.",
            actionURL: URL(string: "https://support.apple.com/en-us/102154"),
            actionTitle: "Apple’s local-snapshot guidance"
          )
        case .insufficientSpace(let required, let available):
          let shortfall = bytesRoundedUp(required - min(required, available))
          return FailureDisplay(
            headline:
              "Free up at least \(shortfall) to install Omarchy",
            plainDetail:
              "Omarchy needs \(bytes(required)); only \(bytes(available)) can be made available within the current safety limits. Free space shown in macOS is not necessarily space available for installation. The disk has not been changed.",
            technicalDetail: technical,
            remedy:
              "Remove files you no longer need in macOS and empty the Trash, then choose Check again. The installer will check the available space again before allowing installation."
          )
        case .noEligibleCandidate:
          return FailureDisplay(
            headline: "There isn’t enough usable disk space",
            plainDetail:
              "The installer couldn’t find a disk allocation that meets its requirements. Free space shown in macOS is not necessarily space that can be released for a new partition. The disk has not been changed.",
            technicalDetail: technical,
            remedy:
              "Back up your Mac first. Check available storage and any pending macOS updates, then choose Check again. Local snapshots can also limit resizing, but the installer could not confirm that cause. Freeing files alone may not make partition space available."
          )
        }
      }
      if error is URLError {
        return FailureDisplay(
          headline: "The network request didn’t finish",
          plainDetail: "Check your internet connection before continuing.",
          technicalDetail: technical, remedy: "Check your internet connection, then try again.")
      }

      if let preparation = error as? InstallerPlanPreparationError {
        switch preparation {
        case .unsupportedDevice(let identifier):
          return unsupportedModel(deviceIdentifier: identifier, technicalDetail: technical)
        default:
          return FailureDisplay(
            headline: "An installation plan couldn’t be prepared",
            plainDetail:
              "The installer couldn’t prepare a valid disk plan. Installation has not started.",
            technicalDetail: technical,
            remedy: "Review the error details, then check this Mac again."
          )
        }
      }

      if let preparation = error as? InstallerAssetPreparationError {
        switch preparation {
        case .installerOutdated(let current, let minimum, let downloadURL):
          return FailureDisplay(
            headline: "This installer is out of date",
            plainDetail:
              "This release requires installer \(minimum) or later. You’re using \(current).",
            technicalDetail: technical,
            remedy:
              "Download the latest \(windowTitle) and open it.",
            actionURL: downloadURL,
            actionTitle: downloadInstaller
          )
        case .hostBlocked(let reason):
          return FailureDisplay(
            headline: "This Mac isn’t supported yet",
            plainDetail: reason,
            technicalDetail: technical,
            isBlockedModel: true
          )
        case .unsupportedDevice(let identifier):
          return unsupportedModel(deviceIdentifier: identifier, technicalDetail: technical)
        case .noMacRelease:
          return noMacRelease(technicalDetail: technical)
        case .notInCatalog(let identifier, let model, let supported):
          return unsupportedModel(
            deviceIdentifier: identifier,
            modelIdentifier: model,
            supportedDeviceIdentifiers: supported,
            technicalDetail: technical
          )
        case .deliveryMetadataUnavailable:
          return FailureDisplay(
            headline: "Installation files aren’t listed for this Mac",
            plainDetail:
              "The signed release supports this Mac but doesn’t provide its installation file details. Installation cannot continue.",
            technicalDetail: technical,
            remedy: "Check again later."
          )
        }
      }

      if let staging = error as? ArtifactStageError {
        switch staging {
        case .digestMismatch, .sizeMismatch, .destinationConflict,
          .partSizeSumMismatch:
          return FailureDisplay(
            headline: "An installation file couldn’t be verified",
            plainDetail:
              "The file did not pass verification. Installation cannot continue.",
            technicalDetail: technical,
            remedy: "Try downloading the installation files again."
          )
        default:
          return FailureDisplay(
            headline: "The installation files couldn’t be prepared",
            plainDetail: "Installation has not started.",
            technicalDetail: technical,
            remedy: "Review the error details, then try again."
          )
        }
      }

      if let configuration = error as? InstallerReleaseConfigurationError {
        switch configuration {
        case .releaseResourcesUnavailable:
          return FailureDisplay(
            headline: "Installation is unavailable in this build",
            plainDetail: releaseResourcesUnavailable,
            technicalDetail: technical
          )
        case .unexpectedHTTPStatus(404):
          return FailureDisplay(
            headline: "This channel’s release list wasn’t found",
            plainDetail:
              "The release server has no signed release list at this channel’s address, so the installer can’t tell what the channel offers. Installation has not started.",
            technicalDetail: technical,
            remedy:
              "Check again later, or choose another release channel from the menu bar."
          )
        case .unexpectedHTTPStatus:
          return FailureDisplay(
            headline: "The release server returned an error",
            plainDetail: "Installation has not started.",
            technicalDetail: technical,
            remedy: "Review the error details, then try again."
          )
        case .invalidCatalogEnvelope, .invalidCatalogSignature,
          .oversizedDocument:
          return FailureDisplay(
            headline: "The release couldn’t be verified",
            plainDetail:
              "The server response did not pass release verification. Installation cannot continue.",
            technicalDetail: technical,
            remedy: "Check again later."
          )
        default:
          return FailureDisplay(
            headline: "The release is unavailable",
            plainDetail: "Installation has not started.",
            technicalDetail: technical,
            remedy: "Review the error details, then try again."
          )
        }
      }

      if let catalog = error as? SupportCatalogError {
        return FailureDisplay(
          headline: "The support catalog couldn’t be verified",
          plainDetail:
            "The catalog did not meet the installer’s signature or version requirements. Installation cannot continue.",
          technicalDetail: String(describing: catalog),
          remedy: "Try again later, or download the latest installer."
        )
      }

      return FailureDisplay(
        headline: "The installer encountered an error",
        plainDetail:
          "Review the last verified installation step before continuing.",
        technicalDetail: technical,
        remedy:
          "If installation has started, keep your Mac connected to power and check the verified installation record before trying again."
      )
    }

    // MARK: Formatting

    /// Whole-number sizes: "137 GB", "18 MB". Decimal places only add noise
    /// at the scale people choose disk space in.
    public static func bytes(_ value: UInt64) -> String {
      let gb: Double = 1_000_000_000
      let mb: Double = 1_000_000
      let kb: Double = 1_000
      let count = Double(value)
      if count >= gb { return "\(Int((count / gb).rounded())) GB" }
      if count >= mb { return "\(Int((count / mb).rounded())) MB" }
      if count >= kb { return "\(Int((count / kb).rounded())) KB" }
      return "\(value) bytes"
    }

    /// Whole gigabytes, rounded up: for amounts the person must free, where
    /// rounding down would ask for too little.
    public static func bytesRoundedUp(_ value: UInt64) -> String {
      let gb: UInt64 = 1_000_000_000
      return "\(value / gb + (value % gb == 0 ? 0 : 1)) GB"
    }

    public static func shortDigest(_ value: String) -> String {
      let body =
        value.hasPrefix("sha256:")
        ? String(value.dropFirst(7)) : value
      guard body.count > 20 else {
        return body
      }
      return String(body.prefix(8)) + "…" + String(body.suffix(8))
    }
  }
#endif
