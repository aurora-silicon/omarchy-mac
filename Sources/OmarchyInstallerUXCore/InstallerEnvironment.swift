#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import RecoveryAccountCore

  /// Everything a screen renders, derived once by the environment from the
  /// retained trust objects. Display models are render-only: no approval,
  /// confirmation, or execution value is ever rebuilt from them.
  public struct HostDisplay: Equatable, Sendable {
    /// The header line: chip and free space, e.g. "Apple M1 Pro · 464 GB free".
    public let chipAndSpace: String
    /// The header's chip and free space alone, without what Omarchy could
    /// take, so the page can name the size the owner chose instead.
    public let chipAndFreeSpace: String
    public let supported: Bool
    public let powerButtonGuide: MacPowerButtonGuide
    /// Why this Mac cannot install right now, when `supported` is false.
    public let blockingReason: String?
    /// Omarchy installs the inspection found on the disk. Known before any
    /// download, from the bundled validation engine's inventory; the session
    /// refuses to go further when this is not empty.
    public let existingInstalls: [ExistingInstallDisplay]
    /// Why the bundled engine's inventory cannot hold Omarchy. Known before
    /// any download; the session stops here instead of fetching a release
    /// that could not be installed.
    public let spaceShortfall: InstallerAllocationRecommendationError?
    /// Set when the Mac model itself is what blocks installation: its device
    /// identifier (`apple,j504`), its model identifier (`Mac15,3`), and the
    /// device identifiers the signed catalog admits when it could be read.
    public let unsupportedModel: UnsupportedModelDisplay?

    public init(
      chipAndSpace: String,
      chipAndFreeSpace: String? = nil,
      supported: Bool,
      blockingReason: String? = nil,
      existingInstalls: [ExistingInstallDisplay] = [],
      spaceShortfall: InstallerAllocationRecommendationError? = nil,
      unsupportedModel: UnsupportedModelDisplay? = nil,
      powerButtonGuide: MacPowerButtonGuide = .generic
    ) {
      self.chipAndSpace = chipAndSpace
      self.chipAndFreeSpace = chipAndFreeSpace ?? chipAndSpace
      self.supported = supported
      self.powerButtonGuide = powerButtonGuide
      self.blockingReason = blockingReason
      self.existingInstalls = existingInstalls
      self.spaceShortfall = spaceShortfall
      self.unsupportedModel = unsupportedModel
    }

    /// The header line. Before the owner chooses a size it says the most
    /// Omarchy could take; afterwards it names the size they chose.
    public func header(chosenOmarchyBytes: UInt64?) -> String {
      guard let chosenOmarchyBytes else { return chipAndSpace }
      return "\(chipAndFreeSpace) · \(PlainLanguage.bytes(chosenOmarchyBytes)) for Omarchy"
    }
  }

  public struct UnsupportedModelDisplay: Equatable, Sendable {
    public let deviceIdentifier: String
    public let modelIdentifier: String?
    /// Nil when the signed catalog could not be fetched or verified.
    public let supportedDeviceIdentifiers: [String]?

    public init(
      deviceIdentifier: String,
      modelIdentifier: String?,
      supportedDeviceIdentifiers: [String]?
    ) {
      self.deviceIdentifier = deviceIdentifier
      self.modelIdentifier = modelIdentifier
      self.supportedDeviceIdentifiers = supportedDeviceIdentifiers
    }
  }

  public struct PlanFactRow: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    public let isMonospaced: Bool

    public var id: String { label }

    public init(label: String, value: String, isMonospaced: Bool = false) {
      self.label = label
      self.value = value
      self.isMonospaced = isMonospaced
    }
  }

  /// One existing Omarchy install the pinned engine found on this Mac.
  public struct ExistingInstallDisplay: Equatable, Sendable, Identifiable {
    public let sourceIdentifier: String
    public let sizeDescription: String

    public var id: String { sourceIdentifier }

    public init(sourceIdentifier: String, sizeDescription: String) {
      self.sourceIdentifier = sourceIdentifier
      self.sizeDescription = sizeDescription
    }
  }

  /// Plan preparation either yields a reviewable plan or reports the
  /// existing installs it found, which the session refuses. Nothing is
  /// approved or executed from either value.
  public enum PlanPreparationDisplay: Equatable, Sendable {
    case plan(PlanDisplay)
    case existingInstallChoice([ExistingInstallDisplay])
  }

  public struct PlanDisplay: Equatable, Sendable {
    public let diskTotalBytes: UInt64
    public let omarchyBytes: UInt64
    public let bindingDigest: String
    public let minimumBytes: UInt64
    public let maximumBytes: UInt64
    public let releaseDescription: String
    public let targetDescription: String
    public let fixedMacOSBytes: UInt64?
    /// Fresh APFS free space after reserving remaining staging and handoff copies.
    public let macOSFreeBeforeAllocationBytes: UInt64?
    public let recommendedOmarchyBytes: UInt64?
    public static let recommendedMacOSFreeBytes: UInt64 = 38_000_000_000
    /// Whether the user may choose Omarchy's size. A replace plan removes an
    /// existing install and reuses its exact extent, so there is nothing to
    /// drag; showing a divider there invites a re-plan the engine refuses.
    public let isResizable: Bool

    public init(
      diskTotalBytes: UInt64,
      omarchyBytes: UInt64,
      bindingDigest: String,
      isResizable: Bool = true,
      minimumBytes: UInt64? = nil,
      maximumBytes: UInt64? = nil,
      releaseDescription: String = "Verified release",
      targetDescription: String = "Internal storage",
      fixedMacOSBytes: UInt64? = nil,
      macOSFreeBeforeAllocationBytes: UInt64? = nil,
      recommendedOmarchyBytes: UInt64? = nil
    ) {
      self.diskTotalBytes = diskTotalBytes
      self.omarchyBytes = omarchyBytes
      self.bindingDigest = bindingDigest
      self.minimumBytes = minimumBytes ?? omarchyBytes
      self.maximumBytes = maximumBytes ?? omarchyBytes
      self.releaseDescription = releaseDescription
      self.targetDescription = targetDescription
      self.fixedMacOSBytes = fixedMacOSBytes
      self.macOSFreeBeforeAllocationBytes = macOSFreeBeforeAllocationBytes
      self.recommendedOmarchyBytes = recommendedOmarchyBytes
      self.isResizable = isResizable && self.minimumBytes < self.maximumBytes
    }
  }

  extension PlanDisplay {
    /// Shared by the bar, its accessibility value, and the visible warning.
    public func macOSSpaceCaution(for allocation: UInt64) -> String? {
      guard fixedMacOSBytes == nil, let free = macOSFreeBeforeAllocationBytes else { return nil }
      let remaining = free - min(free, allocation)
      guard remaining < Self.recommendedMacOSFreeBytes else { return nil }
      return
        "macOS will have about \(remaining / 1_000_000_000) GB free, less than the recommended 38 GB. You may need to free up space in macOS before an update will install."
    }

    public func spaceCautions(for allocation: UInt64) -> [String] {
      var cautions = macOSSpaceCaution(for: allocation).map { [$0] } ?? []
      if let recommended = recommendedOmarchyBytes, allocation < recommended {
        if allocation <= minimumBytes {
          cautions.append(
            "Omarchy will use its minimum size, \(PlainLanguage.bytes(allocation)), leaving little room for updates and snapshots."
          )
        } else {
          cautions.append(
            "Omarchy will use \(PlainLanguage.bytes(allocation)), less than the recommended \(PlainLanguage.bytes(recommended)), leaving limited room for updates and snapshots."
          )
        }
      }
      return cautions
    }

    public func macOSBytes(for allocation: UInt64) -> UInt64 {
      fixedMacOSBytes ?? (diskTotalBytes - min(diskTotalBytes, allocation))
    }
    public func unallocatedBytes(for allocation: UInt64) -> UInt64 {
      let remaining = diskTotalBytes - min(diskTotalBytes, macOSBytes(for: allocation))
      return remaining - min(remaining, allocation)
    }
  }

  public struct HelperDisplay: Equatable, Sendable {
    public let status: InstallerHelperStatus
    /// This build can install the helper itself when the person authorizes.
    /// Builds without it rely on the installer package having done so.
    public let canInstall: Bool

    /// The privileged helper is in place.
    public var isCurrent: Bool { status == .current }

    /// Installation may be authorized: the helper is in place, or it will be
    /// installed with the credentials the person types.
    public var isReady: Bool { isCurrent || canInstall }

    /// Authorizing will install the helper, so macOS will show a background
    /// item notice.
    public var willInstall: Bool { canInstall && !isCurrent }

    /// The person switched the helper off in Login Items, and this build can
    /// turn it back on if they choose to.
    public var canTurnBackOn: Bool { canInstall && status == .disabled }

    public init(status: InstallerHelperStatus, canInstall: Bool = false) {
      self.status = status
      self.canInstall = canInstall
    }
  }

  /// Why the helper could not be made ready for the action the person
  /// authorized. Nothing touched the disk.
  public enum InstallerHelperSetupError: Error, Equatable, Sendable {
    /// The person cancelled macOS's administrator dialog, or macOS refused.
    case cancelled
    /// The helper is switched off in Login Items.
    case switchedOff
    /// The helper is busy with another job, for example another user's.
    case busy
    /// The account is not an administrator, and the helper needs installing.
    case notAdministrator
    /// This build cannot install the helper, and none is in place.
    case unavailable
    /// The message is for diagnostics only.
    case failed(String)
  }

  /// One artifact row on the preparing screen, fed by
  /// `ArtifactStagingProgress` events keyed by role.
  public struct AssetProgressRow: Equatable, Sendable, Identifiable {
    public let role: String
    public let fileName: String
    public let bytesCompleted: UInt64
    public let totalBytes: UInt64
    public let phase: ArtifactStagingProgress.Phase
    public let partIndex: Int?
    public let partCount: Int?

    public var id: String { role }

    public init(
      role: String,
      fileName: String,
      bytesCompleted: UInt64,
      totalBytes: UInt64,
      phase: ArtifactStagingProgress.Phase,
      partIndex: Int? = nil,
      partCount: Int? = nil
    ) {
      self.role = role
      self.fileName = fileName
      self.bytesCompleted = bytesCompleted
      self.totalBytes = totalBytes
      self.phase = phase
      self.partIndex = partIndex
      self.partCount = partCount
    }

    public init(_ progress: ArtifactStagingProgress) {
      self.init(
        role: progress.role,
        fileName: progress.fileName,
        bytesCompleted: progress.bytesCompleted,
        totalBytes: progress.totalBytes,
        phase: progress.phase,
        partIndex: progress.partIndex,
        partCount: progress.partCount
      )
    }

    /// The rows for a set of staging events keyed by role, in role order.
    public static func rows(
      from progress: [String: ArtifactStagingProgress]
    ) -> [AssetProgressRow] {
      progress.values
        .sorted { $0.role < $1.role }
        .map(AssetProgressRow.init)
    }
  }

  public struct AssetProgressUpdate: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
      case fetchingCatalog
      case downloading
      case inspectingEngine
      case planning
    }

    public let stage: Stage
    public let rows: [AssetProgressRow]

    public init(stage: Stage, rows: [AssetProgressRow] = []) {
      self.stage = stage
      self.rows = rows
    }
  }

  public struct JournalFeedLine: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
      case event
      case checkpoint
      case completion
    }

    public let id: Int
    public let kind: Kind
    public let text: String

    public init(id: Int, kind: Kind, text: String) {
      self.id = id
      self.kind = kind
      self.text = text
    }
  }

  public struct InstallProgressDisplay: Equatable, Sendable {
    public let phaseTitle: String
    public let stageIndex: Int
    public let stageFractions: [Double]
    public let stageLabels: [String]
    public let feed: [JournalFeedLine]
    public let degraded: Bool
    public let startedAt: Date

    public init(
      phaseTitle: String,
      stageIndex: Int,
      stageFractions: [Double],
      stageLabels: [String],
      feed: [JournalFeedLine],
      degraded: Bool,
      startedAt: Date
    ) {
      self.phaseTitle = phaseTitle
      self.stageIndex = stageIndex
      self.stageFractions = stageFractions
      self.stageLabels = stageLabels
      self.feed = feed
      self.degraded = degraded
      self.startedAt = startedAt
    }
  }

  public struct RecoveryStep: Equatable, Sendable, Identifiable {
    public let number: Int
    public let title: String
    /// How to do the step, drawn as help text under the short title.
    public let detail: String?

    public var id: Int { number }

    public init(number: Int, title: String, detail: String? = nil) {
      self.number = number
      self.title = title
      self.detail = detail
    }
  }

  public struct HandoffDisplay: Equatable, Sendable {
    public let headline: String
    public let steps: [RecoveryStep]
    public let warning: String?

    public init(headline: String, steps: [RecoveryStep], warning: String? = nil) {
      self.headline = headline
      self.steps = steps
      self.warning = warning
    }
  }

  public struct CompletionDisplay: Equatable, Sendable {
    public let nextAction: InstallerNextAction
    public let headline: String
    public let subheadline: String
    public let verified: [PlanFactRow]
    public let handoff: HandoffDisplay?

    public init(
      nextAction: InstallerNextAction,
      headline: String,
      subheadline: String,
      verified: [PlanFactRow],
      handoff: HandoffDisplay?
    ) {
      self.nextAction = nextAction
      self.headline = headline
      self.subheadline = subheadline
      self.verified = verified
      self.handoff = handoff
    }
  }

  public struct FailureDisplay: Equatable, Sendable {
    public let headline: String
    public let plainDetail: String
    public let technicalDetail: String?
    public let remedy: String?
    public let retryRecoveryAvailable: Bool
    public let isBlockedModel: Bool
    public let device: HostDisplay?
    /// A supported guidance page or installer download for resolving this failure.
    public let actionURL: URL?
    public let actionTitle: String?
    /// The engine refused the approved plan before changing the disk because
    /// the available space or layout moved. The page offers to prepare a new
    /// plan through the normal size check.
    public let replanAvailable: Bool

    public init(
      headline: String,
      plainDetail: String,
      technicalDetail: String? = nil,
      remedy: String? = nil,
      retryRecoveryAvailable: Bool = false,
      isBlockedModel: Bool = false,
      device: HostDisplay? = nil,
      actionURL: URL? = nil,
      actionTitle: String? = nil,
      replanAvailable: Bool = false
    ) {
      self.headline = headline
      self.plainDetail = plainDetail
      self.technicalDetail = technicalDetail
      self.remedy = remedy
      self.retryRecoveryAvailable = retryRecoveryAvailable
      self.isBlockedModel = isBlockedModel
      self.device = device
      self.actionURL = actionURL
      self.actionTitle = actionTitle
      self.replanAvailable = replanAvailable
    }

    /// The same failure, shown under the header of the Mac it concerns.
    public func on(_ device: HostDisplay) -> FailureDisplay {
      FailureDisplay(
        headline: headline, plainDetail: plainDetail, technicalDetail: technicalDetail,
        remedy: remedy, retryRecoveryAvailable: retryRecoveryAvailable,
        isBlockedModel: isBlockedModel, device: device, actionURL: actionURL,
        actionTitle: actionTitle, replanAvailable: replanAvailable)
    }
  }

  public enum InstallOperationKind: String, Equatable, Sendable {
    case install
    case retryRecoveryAuthorization
  }

  public enum CredentialSheetError: String, Equatable, Sendable {
    case credentialsRejected
    case helperSetupCancelled
    case helperSwitchedOff
    case helperSetupFailed
    case helperBusy
    case notAdministrator
  }

  public struct CredentialSheetContext: Equatable, Sendable {
    public let kind: InstallOperationKind
    public let bindingDigest: String
    public let error: CredentialSheetError?
    /// True while the helper is checking the submitted credentials. The sheet
    /// stays up (fields locked) so a rejection appears in place instead of the
    /// sheet closing, the screen flipping, and the sheet coming back.
    public let isVerifying: Bool
    /// Authorizing will install the helper, so the sheet says macOS will show
    /// a background item notice.
    public let mentionsBackgroundItem: Bool
    /// The helper is switched off in Login Items. The sheet says so, and
    /// authorizing from it turns the helper back on with the typed password;
    /// the person can open Login Items instead.
    public let helperSwitchedOff: Bool

    public init(
      kind: InstallOperationKind,
      bindingDigest: String,
      error: CredentialSheetError? = nil,
      isVerifying: Bool = false,
      mentionsBackgroundItem: Bool = false,
      helperSwitchedOff: Bool = false
    ) {
      self.kind = kind
      self.bindingDigest = bindingDigest
      self.error = error
      self.isVerifying = isVerifying
      self.mentionsBackgroundItem = mentionsBackgroundItem
      self.helperSwitchedOff = helperSwitchedOff
    }

    public func verifying() -> CredentialSheetContext {
      CredentialSheetContext(
        kind: kind, bindingDigest: bindingDigest, error: nil, isVerifying: true,
        mentionsBackgroundItem: mentionsBackgroundItem, helperSwitchedOff: helperSwitchedOff)
    }

    /// The same sheet, reopened with an error.
    public func failed(_ error: CredentialSheetError) -> CredentialSheetContext {
      CredentialSheetContext(
        kind: kind, bindingDigest: bindingDigest, error: error, isVerifying: false,
        mentionsBackgroundItem: mentionsBackgroundItem,
        helperSwitchedOff: helperSwitchedOff || error == .helperSwitchedOff)
    }

    /// The same sheet, now knowing the helper is switched off.
    public func withHelperSwitchedOff() -> CredentialSheetContext {
      CredentialSheetContext(
        kind: kind, bindingDigest: bindingDigest, error: error, isVerifying: isVerifying,
        mentionsBackgroundItem: true, helperSwitchedOff: true)
    }
  }

  public enum CredentialSheetState: Equatable, Sendable {
    case hidden
    case presented(CredentialSheetContext)

    public var context: CredentialSheetContext? {
      guard case .presented(let context) = self else {
        return nil
      }
      return context
    }
  }

  /// The single seam between the SwiftUI screens and the trust chain. The live
  /// implementation retains the trust objects (host inspection, prepared plan,
  /// review, approval, release configuration); the preview implementation
  /// replays a recorded journal. Neither ever hands a credential back.
  public protocol InstallerEnvironment: Sendable {
    var isSimulation: Bool { get }
    func inspectRecoveryAccount() async throws -> RecoveryAccountReply?
    func prepareRecoveryHandoff(ticket: String) async throws -> RecoveryAccountReply
    func prepareRecoveryAccount(ticket: String, username: String, password: Data) async throws
      -> RecoveryAccountReply
    func finalizeRecoveryAccount(ticket: String, password: Data) async throws
      -> RecoveryAccountReply
    func openStartupDisk() -> Bool
    func inspect() async throws -> HostDisplay
    /// `omarchyBytes` asks the planner for that much space for Omarchy; nil
    /// keeps the balanced default. The engine still clamps the request to the
    /// candidate's real minimum and maximum.
    func preparePlan(
      omarchyBytes: UInt64?,
      progress: @escaping @Sendable (AssetProgressUpdate) -> Void
    ) async throws -> PlanPreparationDisplay
    func approve() throws
    func discardApproval()
    /// Re-reads whether the helper is registered and whether this build can
    /// install it.
    func refreshHelperStatus() -> HelperDisplay
    /// Asks the helper itself, so a helper switched off in Login Items shows
    /// as `.disabled`. Quick: a switched-off helper is not registered, so the
    /// connection fails at once.
    func probeHelperStatus() async -> HelperDisplay
    /// Makes the privileged helper ready for the action just authorized,
    /// installing or replacing it with these credentials when needed, and
    /// turning a switched-off helper back on only when the person chose to.
    /// Called before `execute`; it keeps no credential. Throws
    /// `EngineXPCSubmissionError.machineOwnerCredentialsRejected` when the
    /// credentials are wrong, and `InstallerHelperSetupError` otherwise.
    func ensureHelper(
      _ authorization: MachineOwnerAuthorization, reenablingSwitchedOff: Bool
    ) async throws
    func execute(
      operation: InstallOperationKind,
      authorization: MachineOwnerAuthorization,
      encryptLinuxDisk: Bool,
      journal: @escaping @Sendable (Data) -> Void
    ) async throws -> CompletionDisplay

    /// Fail-closed gates preserved verbatim from the previous view model.
    var installationBlocked: Bool { get }
    var engineSupported: Bool { get }
    var hasApprovedPlan: Bool { get }
    var helperStatus: HelperDisplay { get }
    var payloadPrefetchRequired: Bool { get }
    var payloadPrefetchState: PayloadPrefetchState { get }

    /// Asks macOS for a graceful shutdown (the Apple menu's Shut Down).
    /// Returns true when the machine is actually going down; the preview
    /// environment and tests return false so nothing powers off.
    func requestShutdown() -> Bool
    func setEncryptLinuxDisk(_ encrypt: Bool)
    func prefetchPayload(
      progress: @escaping @Sendable (PayloadPrefetchState) -> Void
    ) async throws
    func waitUntilPayloadVerified() async throws
    func cancelPayloadPrefetch()
    /// Starts the planned payload's download again after it failed.
    func restartPayloadPrefetch()
    /// What each release channel's verified catalog offers this Mac. Read
    /// only: it never records a catalog or starts a download.
    func channelAvailability() async -> [ReleaseChannel: ReleaseChannelAvailability]
  }

  extension InstallerEnvironment {
    public func inspectRecoveryAccount() async throws -> RecoveryAccountReply? { nil }
    public func prepareRecoveryHandoff(ticket: String) async throws -> RecoveryAccountReply {
      throw AccountSetupFailure("Recovery handoff is unavailable in this environment.")
    }
    public func prepareRecoveryAccount(ticket: String, username: String, password: Data)
      async throws -> RecoveryAccountReply
    {
      throw AccountSetupFailure("Recovery account setup is unavailable in this environment.")
    }
    public func finalizeRecoveryAccount(ticket: String, password: Data) async throws
      -> RecoveryAccountReply
    {
      throw AccountSetupFailure("Recovery account setup is unavailable in this environment.")
    }
    public func openStartupDisk() -> Bool { false }
    public var isSimulation: Bool { false }
    public func requestShutdown() -> Bool { false }
    public var payloadPrefetchRequired: Bool { false }
    public var payloadPrefetchState: PayloadPrefetchState { .verified }
    public func setEncryptLinuxDisk(_ encrypt: Bool) {}
    public func prefetchPayload(
      progress: @escaping @Sendable (PayloadPrefetchState) -> Void
    ) async throws {
      progress(.verified)
    }
    public func waitUntilPayloadVerified() async throws {}
    public func cancelPayloadPrefetch() {}
    public func restartPayloadPrefetch() {}
    public func channelAvailability() async -> [ReleaseChannel: ReleaseChannelAvailability] {
      [:]
    }
  }
#endif
