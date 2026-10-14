import AppKit
import Foundation
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore

/// The real installer environment.
///
/// It owns the trust objects the screens must never see — the host inspection,
/// the engine transcripts, the prepared plan, the review, the approval, and the
/// release configuration — and hands the UI only render-only display models.
/// Approval is always rebuilt from the retained review, never from a display
/// model, and no credential is ever stored here.
final class LiveInstallerEnvironment: InstallerEnvironment, @unchecked Sendable {
  private let lock = NSLock()
  private var hostInspection: AppleSiliconHostInspection?
  private var engineInspection: ValidatedEngineTranscript?
  private var engineInspectionTranscript: Data?
  private var engineInspectionFailure: String?
  private var planReview: InstallerPlanReview?
  private var preparedPlan: PreparedInstallerPlanExecution?
  private var planApproval: CandidateBoundPlanApproval?
  private var reusableAssets: PreparedInstallerAssets?
  private var releaseConfiguration: InstallerReleaseConfiguration?
  private let buildProfile = InstallerBuildProfile.current
  private var encryptLinuxDisk = true
  private var selectedLane = ReleaseChannel.stable.rawValue
  private let prefetch = PayloadPrefetchOrchestrator()
  private var plannedPayload: StagedInstallerArtifact?

  private func accountClient() throws -> AuthenticatedEngineXPCSubmitter {
    let configuration = try InstallerReleaseConfigurationLocator().loadFromMainBundle()
    return try AuthenticatedEngineXPCSubmitter(
      machServiceName: configuration.helperMachServiceName,
      helperCodeSigningRequirement: configuration.helperCodeSigningRequirement)
  }

  func inspectRecoveryAccount() async throws -> RecoveryAccountReply? {
    guard refreshHelperStatus().isReady else { return nil }
    // A helper another build installed refuses this app until helper setup
    // replaces it; until then it has no installation to report.
    guard await probeHelperStatus().isCurrent else { return nil }
    let reply = try await accountClient().recoveryAccount(action: "inspect")
    return reply.target == nil ? nil : reply
  }

  func prepareRecoveryHandoff(ticket: String) async throws -> RecoveryAccountReply {
    try await accountClient().recoveryAccount(action: "handoff", ticket: ticket)
  }

  func openStartupDisk() -> Bool {
    NSWorkspace.shared.open(
      URL(fileURLWithPath: "/System/Library/PreferencePanes/StartupDisk.prefPane"))
  }

  var payloadPrefetchRequired: Bool { true }

  var payloadPrefetchState: PayloadPrefetchState {
    prefetch.currentState()
  }
  // MARK: Fail-closed gates

  var installationBlocked: Bool {
    lock.withLock {
      guard let hostInspection else {
        return true
      }
      if case .blocked = hostInspection.eligibility {
        return true
      }
      return false
    }
  }

  var engineSupported: Bool {
    lock.withLock { engineInspection?.support == .supported }
  }

  var hasApprovedPlan: Bool {
    lock.withLock {
      preparedPlan != nil && planApproval != nil && releaseConfiguration != nil
    }
  }

  var helperStatus: HelperDisplay {
    InstallerHelperSetup.display
  }

  // MARK: Inspection

  func inspect() async throws -> HostDisplay {
    let host = try await Task.detached(priority: .userInitiated) {
      try AppleSiliconHostInspector().inspect()
    }.value

    var engine: ValidatedEngineTranscript?
    var transcript: Data?
    var engineFailure: String?
    do {
      let inspection = try await EngineInspectionRunner().inspect()
      guard
        inspection.validated.deviceIdentifier == host.identity.deviceIdentifier
      else {
        engineFailure = PlainLanguage.engineIdentityMismatch
        throw InstallerAppError.hostChanged
      }
      engine = inspection.validated
      transcript = inspection.transcript
    } catch ValidationEngineArtifactError.unavailable {
      engineFailure = PlainLanguage.engineUnavailable
    } catch InstallerAppError.hostChanged {
      // engineFailure already set above.
    } catch {
      engineFailure =
        "The disk compatibility check failed. Installation is unavailable. Details: \(String(describing: error))"
    }

    lock.withLock {
      hostInspection = host
      engineInspection = engine
      engineInspectionTranscript = transcript
      engineInspectionFailure = engineFailure
      planReview = nil
      preparedPlan = nil
      planApproval = nil
      releaseConfiguration = nil
    }
    cancelPayloadPrefetch()

    var unsupportedModel: UnsupportedModelDisplay?
    let modelRefused =
      AppleSiliconHostInspector.isExplicitlyUnsupported(host.identity.deviceIdentifier)
      || engine?.support == .unsupported
    if modelRefused {
      unsupportedModel = UnsupportedModelDisplay(
        deviceIdentifier: host.identity.deviceIdentifier,
        modelIdentifier: host.identity.model,
        supportedDeviceIdentifiers: await supportedDeviceIdentifiers()
      )
    }

    return display(
      host: host, engine: engine, engineFailure: engineFailure,
      unsupportedModel: unsupportedModel)
  }

  /// The signed catalog's model list for the unsupported-Mac message. Any
  /// failure (offline, unsigned, rolled back) just leaves the list out.
  private func supportedDeviceIdentifiers() async -> [String]? {
    guard let configuration = try? InstallerReleaseConfigurationLocator().loadFromMainBundle(),
      let workspace = try? installerWorkspace()
    else {
      return nil
    }
    let channel = ReleaseChannelPreference().resolve(configuration: configuration)
    // Unreadable or unsafe rollback state shows no list rather than skipping
    // the rollback check.
    let previouslyAccepted: AcceptedCatalogIdentity?
    do {
      previouslyAccepted = try AcceptedCatalogIdentityStore(
        directory: workspace.state,
        channel: channel
      ).load()
    } catch {
      return nil
    }
    return try? await InstallerReleaseAssetCoordinator().supportedDeviceIdentifiers(
      configuration: configuration,
      channel: channel,
      validationTime: Date(),
      previouslyAcceptedCatalog: previouslyAccepted
    )
  }

  /// Every channel's catalog, checked side by side for this Mac. A channel
  /// whose rollback state cannot be read counts as unverifiable rather than
  /// skipping the rollback check.
  func channelAvailability() async -> [ReleaseChannel: ReleaseChannelAvailability] {
    guard let host = lock.withLock({ hostInspection }) else { return [:] }
    let deviceIdentifier = host.identity.deviceIdentifier
    let everyChannelFailed = { (error: any Error) in
      Dictionary(
        uniqueKeysWithValues: ReleaseChannel.allCases.map {
          ($0, ReleaseChannelAvailability(checkError: error))
        })
    }
    let configuration: InstallerReleaseConfiguration
    do {
      configuration = try InstallerReleaseConfigurationLocator().loadFromMainBundle()
    } catch {
      return everyChannelFailed(error)
    }
    // A sealed catalog answers for every channel alike, so it says nothing
    // about what each channel offers.
    guard configuration.sealedCatalogDocuments == nil else { return [:] }
    let stateDirectory: URL
    do {
      stateDirectory = try installerWorkspace().state
    } catch {
      return everyChannelFailed(error)
    }
    return await withTaskGroup(
      of: (ReleaseChannel, ReleaseChannelAvailability).self
    ) { group in
      for channel in ReleaseChannel.allCases {
        group.addTask {
          let previouslyAccepted: AcceptedCatalogIdentity?
          do {
            previouslyAccepted = try AcceptedCatalogIdentityStore(
              directory: stateDirectory,
              channel: channel
            ).load()
          } catch {
            return (channel, ReleaseChannelAvailability(checkError: error))
          }
          return (
            channel,
            await InstallerReleaseAssetCoordinator().availability(
              configuration: configuration,
              channel: channel,
              deviceIdentifier: deviceIdentifier,
              validationTime: Date(),
              previouslyAcceptedCatalog: previouslyAccepted
            )
          )
        }
      }
      var result = [ReleaseChannel: ReleaseChannelAvailability]()
      for await (channel, availability) in group {
        result[channel] = availability
      }
      return result
    }
  }

  // MARK: Plan preparation

  func preparePlan(
    omarchyBytes: UInt64?,
    progress: @escaping @Sendable (AssetProgressUpdate) -> Void
  ) async throws -> PlanPreparationDisplay {
    let (host, hasTranscript) = lock.withLock {
      let retained = (hostInspection, engineInspectionTranscript != nil)
      planReview = nil
      preparedPlan = nil
      planApproval = nil
      releaseConfiguration = nil
      return retained
    }

    guard let host, hasTranscript else {
      throw InstallerAppError.inspectionRequired
    }

    progress(AssetProgressUpdate(stage: .fetchingCatalog))

    let configuration = try InstallerReleaseConfigurationLocator()
      .loadFromMainBundle()
    let workspace = try installerWorkspace()
    let channel = ReleaseChannelPreference().resolve(configuration: configuration)
    let catalogStore = AcceptedCatalogIdentityStore(
      directory: workspace.state,
      channel: channel
    )
    let previouslyAcceptedCatalog = try catalogStore.load()
    let validationTime = Date()

    let collector = StagingProgressCollector(publish: progress)
    let release = try await InstallerReleaseAssetCoordinator()
      .prepareRelease(
        InstallerReleasePreparationRequest(
          host: host,
          configuration: configuration,
          channel: channel,
          validationTime: validationTime,
          previouslyAcceptedCatalog: previouslyAcceptedCatalog,
          installerVersion: InstallerVersion.current(),
          stagingDirectory: workspace.staging
        ),
        progress: { event in
          collector.record(event)
        },
        previouslyPrepared: lock.withLock { reusableAssets },
        includePayload: false
      )
    lock.withLock {
      reusableAssets = release.assets
      selectedLane = channel.rawValue
    }
    try catalogStore.store(release.assets.catalogIdentity)
    // The payload is pinned by the verified catalog and does not depend on the
    // plan, so it downloads while the engine checks the Mac and the owner picks
    // a size. The session cancels it if this preparation fails.
    beginPayloadPrefetch(release.assets.payload)

    progress(
      AssetProgressUpdate(stage: .inspectingEngine, rows: collector.rows())
    )

    // Sampled before the engine reads free space, so a download that moves on
    // during inspection only makes the reserve more cautious.
    let payloadBytesOnDisk = prefetch.bytesOnDisk(for: release.assets.payload)
    let planningReserve = release.assets.planningReserveBytes(
      payloadBytesOnDisk: payloadBytesOnDisk)
    let freshHost = try await Task.detached(priority: .userInitiated) {
      try AppleSiliconHostInspector().inspect()
    }.value
    guard freshHost.identity == host.identity else { throw InstallerAppError.hostChanged }
    let stagedEngine = release.assets.engine
    let archive = try PinnedAsahiEngineArchive(
      fileURL: stagedEngine.fileURL,
      expectedDigest: stagedEngine.artifact.expectedDigest,
      expectedSizeBytes: stagedEngine.artifact.expectedSizeBytes
    )
    let signedInspection = try await EngineInspectionRunner().inspect(archive)
    guard
      signedInspection.validated.deviceIdentifier
        == host.identity.deviceIdentifier,
      signedInspection.validated.support == .supported,
      let inventory = signedInspection.validated.inventory
    else {
      throw InstallerPlanPreparationError.unsupportedDevice(
        host.identity.deviceIdentifier
      )
    }

    progress(AssetProgressUpdate(stage: .planning, rows: collector.rows()))

    // Existing installs are never replaced or joined: report them and let
    // the session refuse.
    let existing = Self.existingInstalls(in: signedInspection.validated)
    if !existing.isEmpty {
      return .existingInstallChoice(existing)
    }
    let recommendation = try InstallerAllocationRecommendation(
      inventory: inventory,
      targetBytes: omarchyBytes ?? InstallerAllocationRecommendation.balancedTargetBytes,
      reservedBytes: planningReserve,
      snapshotConstraint: {
        APFSSnapshotInspector().constraint(in: host.storage)
      }
    )
    let candidate = recommendation.candidate
    let requestedLengthBytes = recommendation.requestedLengthBytes

    let prepared = try await InstallerPlanPreparationCoordinator()
      .prepareExecution(
        InstallerPlanPreparationRequest(
          host: host,
          release: release,
          configuration: configuration,
          inspectionTranscript: signedInspection.transcript,
          candidate: candidate,
          requestedLengthBytes: requestedLengthBytes,
          validationTime: validationTime,
          previouslyAcceptedCatalog: previouslyAcceptedCatalog,
          scratchDirectory: workspace.scratch
        )
      )

    lock.withLock {
      preparedPlan = prepared
      planReview = prepared.review
      releaseConfiguration = configuration
    }

    return .plan(
      Self.planDisplay(
        review: prepared.review, host: freshHost, recommendation: recommendation,
        reservedBytes: planningReserve,
        release:
          "\(channel.rawValue.capitalized) · \(release.assets.payload.fileURL.lastPathComponent)"
      ))
  }

  // MARK: Approval

  /// The confirmation is rebuilt field by field from the retained review — the
  /// same values the Exact plan panel rendered — and `approve(confirming:)`
  /// re-checks every one of them.
  func approve() throws {
    let review = lock.withLock { planReview }

    guard let review else {
      throw InstallerAppError.approvalUnavailable
    }
    let confirmation = InstallerOwnerPlanConfirmation(
      bindingDigest: review.identity.bindingDigest,
      planDigest: review.plan.planDigest,
      deviceIdentifier: review.plan.deviceIdentifier,
      storeIdentifier: review.plan.storeIdentifier,
      sourceIdentifier: review.plan.sourceIdentifier,
      offsetBytes: review.plan.offsetBytes,
      lengthBytes: review.plan.lengthBytes,
      requiredHumanSteps: review.plan.requiredHumanSteps
    )
    do {
      let approval = try review.approve(confirming: confirmation)
      lock.withLock { planApproval = approval }
    } catch {
      lock.withLock { planApproval = nil }
      throw error
    }
  }

  func discardApproval() {
    lock.withLock { planApproval = nil }
  }

  // MARK: Helper

  func refreshHelperStatus() -> HelperDisplay {
    helperStatus
  }

  func probeHelperStatus() async -> HelperDisplay {
    await InstallerHelperSetup.probeDisplay()
  }

  func ensureHelper(
    _ authorization: MachineOwnerAuthorization, reenablingSwitchedOff: Bool
  ) async throws {
    try await InstallerHelperSetup.ensure(
      authorization, reenablingSwitchedOff: reenablingSwitchedOff)
  }

  // MARK: Shutdown

  /// The graceful route: the same Apple Event the Apple menu sends. Apps with
  /// unsaved work can still object, and nothing here needs the privileged
  /// helper.
  func requestShutdown() -> Bool {
    let target = NSAppleEventDescriptor(
      bundleIdentifier: "com.apple.loginwindow"
    )
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass),
      eventID: AEEventID(kAEShutDown),
      targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    do {
      _ = try event.sendEvent(options: [.noReply], timeout: 3)
      return true
    } catch {
      return false
    }
  }

  func setEncryptLinuxDisk(_ encrypt: Bool) {
    lock.withLock { encryptLinuxDisk = buildProfile.allowsEncryption ? encrypt : false }
  }

  func cancelPayloadPrefetch() {
    lock.withLock { plannedPayload = nil }
    prefetch.cancel()
  }

  func restartPayloadPrefetch() {
    guard let payload = lock.withLock({ plannedPayload }) else { return }
    // A failed or cancelled download of the same digest starts afresh; a
    // running one is left alone.
    prefetch.begin(payload: payload)
  }

  func prefetchPayload(
    progress: @escaping @Sendable (PayloadPrefetchState) -> Void
  ) async throws {
    try await prefetch.waitUntilVerified(progress: progress)
  }

  func waitUntilPayloadVerified() async throws {
    try await prefetch.waitUntilVerified(progress: { _ in })
  }

  private func beginPayloadPrefetch(_ payload: StagedInstallerArtifact) {
    lock.withLock { plannedPayload = payload }
    prefetch.begin(payload: payload)
  }

  private func recordInstallConf(
    configuration: InstallerReleaseConfiguration,
    plan: ValidatedEnginePlan,
    authorization: MachineOwnerAuthorization,
    encrypt: Bool
  ) async -> InstallConfHandoff {
    let lane = lock.withLock { selectedLane }
    guard let conf = try? InstallConf(encrypt: encrypt, lane: lane) else {
      return .notRecorded
    }
    do {
      let submitter = try AuthenticatedEngineXPCSubmitter(
        machServiceName: configuration.helperMachServiceName,
        helperCodeSigningRequirement: configuration.helperCodeSigningRequirement
      )
      let helper = AuthorizedInstallConfESPHelper(
        submitter: submitter,
        authorization: authorization
      )
      return await InstallConfESPWriter(helper: helper).record(
        conf,
        storeIdentifier: plan.storeIdentifier,
        offsetBytes: plan.offsetBytes,
        lengthBytes: plan.lengthBytes
      )
    } catch {
      return .notRecorded
    }
  }

  // MARK: Execution

  func execute(
    operation: InstallOperationKind,
    authorization: MachineOwnerAuthorization,
    encryptLinuxDisk: Bool,
    journal: @escaping @Sendable (Data) -> Void
  ) async throws -> CompletionDisplay {
    guard buildProfile.allowsEncryption || !encryptLinuxDisk else {
      throw InstallerPreSubmissionFailure(
        NSError(
          domain: "OmarchyPrivateTest", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "This private M3 test supports plain installation only."
          ]
        ))
    }
    let executionStarted = ProcessInfo.processInfo.systemUptime
    let (prepared, approval, configuration, host) = lock.withLock {
      (preparedPlan, planApproval, releaseConfiguration, hostInspection)
    }

    guard let prepared, let approval, let configuration, let host else {
      throw InstallerPreSubmissionFailure(InstallerAppError.approvalUnavailable)
    }

    // Re-inspection identity match: the Mac that is about to be written to
    // must still be the Mac the plan was bound to.
    let handoffDirectory: URL
    do {
      let currentHost = try AppleSiliconHostInspector().inspect()
      guard currentHost.identity.deviceIdentifier == host.identity.deviceIdentifier else {
        throw InstallerAppError.hostChanged
      }
      handoffDirectory = try installerWorkspace().handoff
    } catch {
      throw InstallerPreSubmissionFailure(error)
    }

    let coordinator = InstallerExecutionCoordinator()
    let progress: InstallerExecutionProgress
    do {
      switch operation {
      case .install:
        progress = try await coordinator.execute(
          prepared,
          approval: approval,
          configuration: configuration,
          handoffDirectory: handoffDirectory,
          machineOwnerAuthorization: authorization,
          journalProgress: journal
        )
      case .retryRecoveryAuthorization:
        progress = try await coordinator.retryRecoveryAuthorization(
          prepared,
          approval: approval,
          configuration: configuration,
          handoffDirectory: handoffDirectory,
          machineOwnerAuthorization: authorization,
          journalProgress: journal
        )
      }
    } catch let EngineXPCSubmissionError.engineFailed(notice) {
      EngineFailureUserLog.write(notice, operation: String(describing: operation))
      throw EngineXPCSubmissionError.engineFailed(notice)
    }
    var installConf: InstallConfHandoff = .recorded
    let handoffOperation: EngineHandoffOperation =
      operation == .retryRecoveryAuthorization ? .retryRecoveryAuthorization : .install
    if InstallConfRecordPolicy.shouldRecord(
      operation: handoffOperation, nextAction: progress.nextAction)
    {
      installConf = await recordInstallConf(
        configuration: configuration,
        plan: prepared.review.plan,
        authorization: authorization,
        encrypt: encryptLinuxDisk
      )
      if operation == .install {
        InstallationTimingHistory.recordCompleted(
          seconds: ProcessInfo.processInfo.systemUptime - executionStarted)
      }
    }
    return Self.completionDisplay(progress, installConf: installConf)
  }

  // MARK: Display mapping

  private func display(
    host: AppleSiliconHostInspection,
    engine: ValidatedEngineTranscript?,
    engineFailure: String?,
    unsupportedModel: UnsupportedModelDisplay?
  ) -> HostDisplay {
    let blocked: Bool
    if case .blocked = host.eligibility {
      blocked = true
    } else {
      blocked = false
    }

    let existing = Self.existingInstalls(in: engine)
    let space = existing.isEmpty ? Self.spaceCheck(engine: engine, host: host) : nil
    let chipAndFreeSpace =
      "\(host.identity.chip) · \(PlainLanguage.bytes(host.storage.containerFreeBytes)) free"
    var chipAndSpace = chipAndFreeSpace
    if case .fits(let maximumBytes) = space {
      chipAndSpace += " · up to \(PlainLanguage.bytes(maximumBytes)) for Omarchy"
    }

    return HostDisplay(
      chipAndSpace: chipAndSpace,
      chipAndFreeSpace: chipAndFreeSpace,
      supported: !blocked && engine?.support == .supported,
      blockingReason: blockingReason(host: host, engineFailure: engineFailure),
      existingInstalls: existing,
      spaceShortfall: space?.shortfall,
      unsupportedModel: unsupportedModel,
      powerButtonGuide: MacPowerButtonGuide(
        deviceIdentifier: host.identity.deviceIdentifier, modelIdentifier: host.identity.model)
    )
  }

  private enum SpaceCheck {
    case fits(maximumBytes: UInt64)
    case shortfall(InstallerAllocationRecommendationError)

    var shortfall: InstallerAllocationRecommendationError? {
      if case .shortfall(let error) = self { error } else { nil }
    }
  }

  /// Runs the allocation recommendation on the bundled engine's inventory, so
  /// a disk that cannot hold Omarchy is reported before the catalog is fetched
  /// or the release downloaded. The handoff reserve is not known yet, so this
  /// can only be more generous than the check after the download.
  private static func spaceCheck(
    engine: ValidatedEngineTranscript?,
    host: AppleSiliconHostInspection
  ) -> SpaceCheck? {
    guard engine?.support == .supported, let inventory = engine?.inventory else {
      return nil
    }
    do {
      let recommendation = try InstallerAllocationRecommendation(
        inventory: inventory,
        snapshotConstraint: { APFSSnapshotInspector().constraint(in: host.storage) }
      )
      return .fits(maximumBytes: recommendation.maximumBytes)
    } catch let error as InstallerAllocationRecommendationError {
      return .shortfall(error)
    } catch {
      return nil
    }
  }

  /// Existing Omarchy installs the bundled engine's inventory reports as
  /// replace candidates. Read at the welcome stage, so the installer can
  /// refuse before it fetches the catalog or downloads anything.
  static func existingInstalls(
    in engine: ValidatedEngineTranscript?
  ) -> [ExistingInstallDisplay] {
    guard let inventory = engine?.inventory else {
      return []
    }
    return inventory.candidates
      .filter { $0.kind == "replace" }
      .map { existing in
        ExistingInstallDisplay(
          sourceIdentifier: existing.sourceIdentifier,
          sizeDescription: PlainLanguage.bytes(existing.lengthBytes)
        )
      }
  }

  private func blockingReason(
    host: AppleSiliconHostInspection,
    engineFailure: String?
  ) -> String? {
    if case .blocked(let reason) = host.eligibility {
      return reason
    }
    return engineFailure
  }

  static func planDisplay(
    review: InstallerPlanReview,
    host: AppleSiliconHostInspection,
    recommendation: InstallerAllocationRecommendation,
    reservedBytes: UInt64 = 0,
    release: String
  ) -> PlanDisplay {
    let length = review.plan.lengthBytes
    let total =
      review.plan.candidateKind == "free"
      ? host.storage.containerSizeBytes + recommendation.candidate.lengthBytes
      : max(host.storage.containerSizeBytes, length)

    return PlanDisplay(
      diskTotalBytes: total,
      omarchyBytes: length,
      bindingDigest: review.identity.bindingDigest,
      isResizable: review.plan.candidateKind != "replace",
      minimumBytes: recommendation.minimumBytes,
      maximumBytes: recommendation.maximumBytes,
      releaseDescription: release,
      targetDescription:
        "Internal storage · \(review.plan.candidateKind == "free" ? "Use free space" : "Resize macOS")",
      fixedMacOSBytes: review.plan.candidateKind == "free" ? host.storage.containerSizeBytes : nil,
      macOSFreeBeforeAllocationBytes:
        review.plan.candidateKind == "resize"
        && recommendation.candidate.sourceIdentifier == host.storage.physicalStoreIdentifier
        ? host.storage.containerFreeBytes - min(host.storage.containerFreeBytes, reservedBytes)
        : nil,
      recommendedOmarchyBytes: recommendation.candidate.recommendedInstallBytes
    )
  }

  static func completionDisplay(
    _ progress: InstallerExecutionProgress,
    installConf: InstallConfHandoff = .recorded
  ) -> CompletionDisplay {
    let handoff: HandoffDisplay?
    let warning = PlainLanguage.installConfWarning(installConf)
    switch progress.nextAction {
    case .enterRecovery:
      handoff = HandoffDisplay(
        headline: PlainLanguage.recoveryHeadline,
        steps: PlainLanguage.recoverySteps(for: progress.requiredHumanSteps),
        warning: warning
      )
    case .attachInstallationMedia:
      handoff = HandoffDisplay(
        headline: PlainLanguage.mediaHeadline,
        steps: PlainLanguage.recoverySteps(for: progress.requiredHumanSteps),
        warning: warning
      )
    default:
      handoff = nil
    }

    return CompletionDisplay(
      nextAction: progress.nextAction,
      headline: progress.nextAction == .verifyInstalledSystem
        ? PlainLanguage.doneHeadline : PlainLanguage.recoveryHeadline,
      subheadline: PlainLanguage.nextActionMessage(
        progress.nextAction, installConf: installConf),
      verified: PlainLanguage.doneVerifiedRows,
      handoff: handoff
    )
  }

  // MARK: Workspace

  private func installerWorkspace() throws
    -> (staging: URL, scratch: URL, state: URL, handoff: URL)
  {
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw InstallerAppError.workspaceUnavailable
    }
    let base = applicationSupport.appendingPathComponent(
      buildProfile.workspaceName,
      isDirectory: true
    )
    let staging = base.appendingPathComponent("staging", isDirectory: true)
    let scratch = base.appendingPathComponent("scratch", isDirectory: true)
    let state = base.appendingPathComponent("state", isDirectory: true)
    let handoff = base.appendingPathComponent("handoff", isDirectory: true)
    try createPrivateDirectoryIfMissing(base)
    try createPrivateDirectoryIfMissing(staging)
    try createPrivateDirectoryIfMissing(scratch)
    try createPrivateDirectoryIfMissing(state)
    try createPrivateDirectoryIfMissing(handoff)
    return (staging, scratch, state, handoff)
  }

  private func createPrivateDirectoryIfMissing(_ directory: URL) throws {
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      return
    }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
  }
}

/// Collects `ArtifactStagingProgress` events by role and republishes them as
/// preparing-screen rows.
private final class StagingProgressCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var latest = [String: ArtifactStagingProgress]()
  private let publish: @Sendable (AssetProgressUpdate) -> Void

  init(publish: @escaping @Sendable (AssetProgressUpdate) -> Void) {
    self.publish = publish
  }

  func record(_ event: ArtifactStagingProgress) {
    let snapshot = lock.withLock { () -> [AssetProgressRow] in
      latest[event.role] = event
      return AssetProgressRow.rows(from: latest)
    }
    publish(AssetProgressUpdate(stage: .downloading, rows: snapshot))
  }

  func rows() -> [AssetProgressRow] {
    lock.withLock { AssetProgressRow.rows(from: latest) }
  }
}
