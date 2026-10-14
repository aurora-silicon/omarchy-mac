#if os(macOS)
  import Foundation
  import Darwin
  import RecoveryAccountCore

  public enum EngineHandoffOperation: String, Equatable, Sendable {
    case install
    case retryRecoveryAuthorization = "retry-recovery-authorization"
  }

  public protocol ImportedEngineHandoffExecuting: Sendable {
    func execute(
      _ package: ImportedEngineHandoffPackage,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data
  }

  public enum ClosedEngineHelperError: Error, Equatable, Sendable {
    case busy
    case invalidOperation
    case invalidMachineOwnerCredentials
    case invalidClientRequirement
    case unsupportedDevice(String)
    case transcriptDeviceMismatch
    case transcriptIncomplete
    case transcriptPlanMismatch
    case installConfPlanIncomplete
    case installConfTargetMismatch
    case installConfReplay
    /// A removal completed and the helper, one the app installed itself, is
    /// uninstalling itself; it takes no more work. The app sets up a fresh
    /// helper for the next action.
    /// Last, so the bridged error codes of the earlier cases never change.
    case retiring
    /// An app from another build is replacing this helper; it takes no new
    /// work meanwhile, so replacing it can never cut a job short.
    case beingReplaced
    /// An earlier removal's record stops before it completed; nothing is
    /// installed until the record and the disk layout are checked.
    case earlierRemovalUnfinished
    /// An earlier removal completed, but the journals of the installation it
    /// removed couldn't be set aside. Left in place, a reinstall at the same
    /// size would find them complete and skip installing, so nothing is
    /// installed until setting them aside works; each request tries again.
    case earlierInstallRecordUncleared
  }

  /// Whether the helper is idle, working on a job, or held for replacement by
  /// one app. One lock decides it, so "may it be replaced?" and "may this job
  /// start?" never both say yes, and only one app at a time holds it.
  final class HelperWorkState: @unchecked Sendable {
    private enum Phase {
      case idle
      case working
      case replacing(token: String, since: ContinuousClock.Instant)
    }

    private let lock = NSLock()
    private var phase = Phase.idle
    /// A hold that is neither renewed nor released (a crashed app) stops
    /// blocking work after this long. The holder renews it immediately before
    /// it replaces the helper, so a lapse never lets it replace a working one.
    private let replacementLapse: TimeInterval

    init(replacementLapse: TimeInterval = 120) {
      self.replacementLapse = replacementLapse
    }

    /// Measured on a monotonic clock, so a change to the system time never
    /// shortens or stretches a hold.
    private func lapsed(_ since: ContinuousClock.Instant) -> Bool {
      ContinuousClock.now - since > .seconds(replacementLapse)
    }

    func beginJob() throws {
      try lock.withLock {
        switch phase {
        case .idle:
          phase = .working
        case .working:
          throw ClosedEngineHelperError.busy
        case .replacing(_, let since):
          guard lapsed(since) else { throw ClosedEngineHelperError.beingReplaced }
          phase = .working
        }
      }
    }

    func endJob() {
      lock.withLock {
        if case .working = phase { phase = .idle }
      }
    }

    /// True when no job runs and no other app holds the replacement. The
    /// same token renews its hold; from then on no job starts until it is
    /// released or lapses.
    func beginReplacement(token: String) -> Bool {
      lock.withLock {
        switch phase {
        case .working:
          return false
        case .replacing(let holder, let since) where holder != token && !lapsed(since):
          return false
        case .idle, .replacing:
          phase = .replacing(token: token, since: ContinuousClock.now)
          return true
        }
      }
    }

    /// Releases the hold, only for the app that holds it.
    func cancelReplacement(token: String) {
      lock.withLock {
        if case .replacing(let holder, _) = phase, holder == token { phase = .idle }
      }
    }
  }

  /// A flag set once and read from any thread.
  final class HelperRetirementFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
  }

  public actor ClosedEngineHelperServer {
    private static let explicitlyUnsupportedDevices = ["apple,j614s"]

    private let workingDirectory: URL
    private let credentialValidator: any MachineOwnerCredentialValidating
    private let executor: any ImportedEngineHandoffExecuting
    private let importer: EngineHandoffPackageImporter
    private let removalDisks: any RemovalDiskOperating
    private let removalAdminValidator: @Sendable (MachineOwnerAuthorization) throws -> Void
    private let espDisks: any InstallConfESPDiskOperating
    private let selfUninstaller: any HelperSelfUninstalling
    /// Jobs and replacement share this state; see `HelperWorkState`.
    nonisolated let work: HelperWorkState
    /// Set once a removal completes and the helper is uninstalling itself. Kept
    /// outside the actor so ping and the version check can read it at once,
    /// even while the actor is busy verifying a payload for a long job.
    private nonisolated let retirement = HelperRetirementFlag()
    public nonisolated var isRetiring: Bool { retirement.isSet }
    private var completedInstallPlan: CompletedEngineInstallPlan?
    private var installConfConsumed = false
    private var recoveryAccountTargets: [String: (CompletedRecoveryInstallation, Date)] = [:]
    private var removalPlan:
      (ticket: OmarchyRemovalTicket, plan: OmarchyRemovalPlan, expires: Date)?

    public init(
      workingDirectory: URL,
      executor: any ImportedEngineHandoffExecuting,
      credentialValidator: any MachineOwnerCredentialValidating =
        OpenDirectoryMachineOwnerCredentialValidator(),
      selfUninstaller: any HelperSelfUninstalling = NoHelperSelfUninstall()
    ) {
      self.workingDirectory = workingDirectory
      self.executor = executor
      self.credentialValidator = credentialValidator
      work = HelperWorkState()
      importer = EngineHandoffPackageImporter()
      removalDisks = MacRemovalDiskOperator()
      removalAdminValidator = requireRemovalAdministrator
      espDisks = DiskutilInstallConfESPOperator()
      self.selfUninstaller = selfUninstaller
    }

    init(
      workingDirectory: URL, executor: any ImportedEngineHandoffExecuting,
      credentialValidator: any MachineOwnerCredentialValidating,
      removalDisks: any RemovalDiskOperating,
      removalAdminValidator: @escaping @Sendable (MachineOwnerAuthorization) throws -> Void,
      espDisks: any InstallConfESPDiskOperating = DiskutilInstallConfESPOperator(),
      selfUninstaller: any HelperSelfUninstalling = NoHelperSelfUninstall(),
      work: HelperWorkState = HelperWorkState()
    ) {
      self.workingDirectory = workingDirectory
      self.executor = executor
      self.credentialValidator = credentialValidator
      self.work = work
      importer = EngineHandoffPackageImporter()
      self.removalDisks = removalDisks
      self.removalAdminValidator = removalAdminValidator
      self.espDisks = espDisks
      self.selfUninstaller = selfUninstaller
    }

    public func recoveryAccount(action: String, ticket: String, username: String, password: Data)
      async throws -> RecoveryAccountReply
    {
      guard !isRetiring else { throw ClosedEngineHelperError.retiring }
      guard ["inspect", "handoff", "prepare", "finalize"].contains(action) else {
        throw ClosedEngineHelperError.invalidOperation
      }
      try work.beginJob()
      defer { work.endJob() }
      let directory = workingDirectory
      if action == "inspect" {
        guard
          let completed = try await Task.detached(operation: {
            try RecoveryAccountHandoff.discover(in: directory)
          }).value
        else { return RecoveryAccountReply() }
        let id = UUID().uuidString
        recoveryAccountTargets = recoveryAccountTargets.filter { $0.value.1 > Date() }
        recoveryAccountTargets[id] = (completed, Date().addingTimeInterval(1800))
        let record = try await Task.detached {
          try RecoveryAccountInstaller.inspect(completed.target)
        }.value
        return RecoveryAccountReply(ticket: id, target: completed.target, record: record)
      }
      guard let (approved, expiry) = recoveryAccountTargets[ticket], expiry > Date(),
        let observed = try await Task.detached(operation: {
          try RecoveryAccountHandoff.discover(in: directory, binding: approved.binding)
        }).value,
        observed == approved
      else {
        throw AccountSetupFailure(
          "The account target changed or expired. Reopen this installer to inspect it again.")
      }
      let record: RecoveryAccountRecord? = try await Task.detached {
        if action == "handoff" {
          try RecoveryAccountHandoff.requireStartupSelection(for: observed.target)
          try RecoveryAccountHandoff.updateRecoveryApp(for: observed.target)
          return try RecoveryAccountInstaller.inspect(observed.target)
        }
        if action == "prepare" {
          try RecoveryAccountHandoff.updateRecoveryApp(for: observed.target)
          return try RecoveryAccountInstaller.prepare(
            observed.target, username: username, password: password)
        }
        return try RecoveryAccountInstaller.finalize(observed.target, password: password)
      }.value
      recoveryAccountTargets[ticket] = (observed, Date().addingTimeInterval(1800))
      return RecoveryAccountReply(ticket: ticket, target: observed.target, record: record)
    }

    public func removal(
      ticketID: UUID?, confirmation: String, authorization: MachineOwnerAuthorization?
    ) async throws -> OmarchyRemovalReply {
      guard !isRetiring else { throw ClosedEngineHelperError.retiring }
      try work.beginJob()
      defer { work.endJob() }
      do {
        try settleEarlierRemovals(in: workingDirectory)
      } catch EarlierRemovalProblem.installRecordUncleared {
        throw RemovalFailure(
          message:
            "After an earlier removal, the installer couldn’t set aside its record of the installation it removed. Try again; if this keeps happening, check the saved removal record before changing any disks."
        )
      } catch {
        throw RemovalFailure(
          message:
            "An earlier removal didn’t finish. Check the saved removal record and disk layout before changing any disks."
        )
      }
      let disks = removalDisks
      let validateAdministrator = removalAdminValidator
      if ticketID == nil {
        removalPlan = nil
        let plan = try await Task.detached {
          try OmarchyRemovalPlan(disks: disks)
        }.value
        let ticket = plan.ticket(id: UUID())
        removalPlan = (ticket, plan, Date().addingTimeInterval(300))
        return OmarchyRemovalReply(ticket: ticket, message: plan.summary)
      }
      guard let authorization, let approved = removalPlan,
        approved.ticket.id == ticketID, approved.expires > Date(),
        confirmation == approved.ticket.confirmation
      else {
        throw RemovalFailure(
          message:
            "The confirmation is incorrect or has expired. Close this window and review removal again. Nothing was changed."
        )
      }
      // One use only, including failures. A fresh review must obtain a new plan.
      removalPlan = nil
      let validator = credentialValidator
      let workingDirectory = self.workingDirectory
      let journalURL = workingDirectory.appendingPathComponent(
        "removal-\(approved.ticket.id.uuidString).json")
      let reply = await Task.detached {
        var phase = "checking"
        do {
          do { try validator.validate(authorization) } catch {
            throw RemovalFailure(message: "The macOS account or password was not accepted.")
          }
          try validateAdministrator(authorization)
          let executor = OmarchyRemovalExecutor(disks: disks)
          try executor.execute(approved.plan, authorization: authorization) { next in
            // The private journal is durable before each mutation, without
            // credentials. Its install journals are set aside only after
            // "complete", and the record says so only once that is durable.
            let journal = RemovalJournal(
              plan: approved.plan, phase: next, executionJournalsRetired: false)
            try writeRemovalRecord(
              JSONEncoder().encode(journal), to: journalURL, in: workingDirectory)
            phase = next
          }
          let name = approved.plan.installation?.name
          var message =
            name.map {
              "“\($0)” and its data have been removed. The freed space is now part of macOS."
            } ?? "The free space is now part of macOS."
          do {
            try settleCompletedRemoval(journalURL, in: workingDirectory)
          } catch {
            // The removal itself is done. Installing stays blocked until the
            // journals are set aside: every later request tries again.
            message +=
              " The installer couldn’t yet set aside its record of the earlier installation. It tries again before the next installation and won’t install until that works."
          }
          return OmarchyRemovalReply(completed: true, message: message)
        } catch {
          let detail = (error as? RemovalFailure)?.message ?? "macOS could not complete removal."
          let message: String
          if phase == "checking" {
            message =
              (error as? RemovalFailure)?.complete == true
              ? detail : "\(detail) No disk changes were made."
          } else if approved.plan.kind == .freeSpace {
            message =
              "macOS couldn’t confirm it took the free space. The space may still be unallocated. \(detail) Don’t start again; the removal record was kept for recovery."
          } else if phase == "returning-space-to-macos" || phase == "complete" {
            message =
              "“\(approved.plan.installation?.name ?? "Omarchy")” was removed, but the installer couldn’t confirm its space went back to macOS. The space may still be unallocated. \(detail) Don’t start removal again; the removal record was kept for recovery."
          } else {
            message =
              "Removal stopped, and some data in “\(approved.plan.installation?.name ?? "Omarchy")” may already be deleted. \(detail) Don’t start removal again; the removal record was kept for recovery."
          }
          return OmarchyRemovalReply(requiresReview: phase != "checking", message: message)
        }
      }.value
      if reply.completed, selfUninstaller.uninstallsAfterRemoval {
        // Nothing of Omarchy is left, so a helper the app installed itself
        // goes too; the app sets it up again at the next install. It takes no
        // more work from here on, before this reply even leaves. A helper the
        // installer package put in place stays and keeps taking work, so the
        // next install needs no package.
        retirement.set()
        selfUninstaller.uninstallAfterRemoval()
      }
      return reply
    }

    /// What this helper's records say about a removal whose reply the app
    /// lost. Settles earlier removals first, as any new request would, so a
    /// completed removal whose install journals were not set aside yet gets
    /// another try now.
    public func removalFinalization(ticketID: UUID) -> RemovalFinalization {
      guard !isRetiring else { return .unknown }
      do { try work.beginJob() } catch { return .busy }
      defer { work.endJob() }
      let record = workingDirectory.appendingPathComponent(
        "removal-\(ticketID.uuidString).json")
      guard FileManager.default.fileExists(atPath: record.path) else { return .unknown }
      do {
        try settleEarlierRemovals(in: workingDirectory)
      } catch EarlierRemovalProblem.installRecordUncleared {
        return .installRecordUncleared
      } catch {
        return .unfinished
      }
      return .finalized
    }

    /// `progress` is optional and advisory: when a connected app exports the
    /// journal callback, the helper tails the run's journal and forwards whole
    /// lines. Passing nil reproduces the previous behavior exactly.
    public func submit(
      packageDirectory: FileHandle,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation = .install,
      progress: (any EngineJournalProgressSink)? = nil
    ) async throws -> Data {
      guard !isRetiring else { throw ClosedEngineHelperError.retiring }
      try work.beginJob()
      defer { work.endJob() }
      do {
        try settleEarlierRemovals(in: workingDirectory)
      } catch EarlierRemovalProblem.installRecordUncleared {
        throw ClosedEngineHelperError.earlierInstallRecordUncleared
      } catch {
        throw ClosedEngineHelperError.earlierRemovalUnfinished
      }

      do {
        try InstallerPerformance.measure("credential_validation") {
          try credentialValidator.validate(authorization)
        }
      } catch {
        throw ClosedEngineHelperError.invalidMachineOwnerCredentials
      }

      let package = try InstallerPerformance.measure("helper_import") {
        try importer.prepare(from: packageDirectory, in: workingDirectory)
      }
      defer { try? FileManager.default.removeItem(at: package.packageURL) }

      guard
        !Self.explicitlyUnsupportedDevices.contains(
          package.deviceIdentifier
        )
      else {
        throw ClosedEngineHelperError.unsupportedDevice(
          package.deviceIdentifier
        )
      }

      var tailer: EngineJournalTailer?
      if let progress,
        let journalURL = EngineJournalLocator.journalURL(
          workingDirectory: workingDirectory,
          bindingDigest: package.bindingDigest
        )
      {
        let started = EngineJournalTailer(
          journalURL: journalURL,
          expectedOwner: geteuid(),
          sink: progress
        )
        await started.start()
        tailer = started
      }

      let result: Data
      do {
        result = try await executor.execute(
          package,
          authorization: authorization,
          operation: operation
        )
      } catch {
        await tailer?.stop()
        if case .engineFailed(let report) = error as? PinnedAsahiEngineExecutionError {
          // The redacted stderr tail stays here, root-only; only the notice
          // travels back to the app.
          EngineFailureDiagnosticsStore.write(
            report,
            operation: operation.rawValue,
            in: workingDirectory
          )
        }
        throw error
      }
      await tailer?.stop()

      let transcript = try AppleInstallerTrustCore()
        .validateEngineTranscript(result)
      guard transcript.support == .supported else {
        throw ClosedEngineHelperError.unsupportedDevice(
          package.deviceIdentifier
        )
      }
      guard transcript.deviceIdentifier == package.deviceIdentifier,
        transcript.plan?.deviceIdentifier == package.deviceIdentifier
      else {
        throw ClosedEngineHelperError.transcriptDeviceMismatch
      }
      guard transcript.plan?.planDigest == package.planDigest else {
        throw ClosedEngineHelperError.transcriptPlanMismatch
      }
      guard transcript.completion != nil else {
        throw ClosedEngineHelperError.transcriptIncomplete
      }
      if let plan = transcript.plan {
        let completed = CompletedEngineInstallPlan(
          storeIdentifier: plan.storeIdentifier,
          offsetBytes: plan.offsetBytes,
          lengthBytes: plan.lengthBytes
        )
        if completedInstallPlan != completed {
          installConfConsumed = false
        }
        completedInstallPlan = completed
      }
      return result
    }

    public func writeInstallConf(
      document: Data,
      storeIdentifier: String,
      offsetBytes: UInt64,
      lengthBytes: UInt64,
      authorization: MachineOwnerAuthorization
    ) async throws {
      guard !isRetiring else { throw ClosedEngineHelperError.retiring }
      try work.beginJob()
      defer { work.endJob() }
      do {
        try credentialValidator.validate(authorization)
      } catch {
        throw ClosedEngineHelperError.invalidMachineOwnerCredentials
      }
      guard let completed = completedInstallPlan else {
        throw ClosedEngineHelperError.installConfPlanIncomplete
      }
      guard !installConfConsumed else {
        throw ClosedEngineHelperError.installConfReplay
      }
      guard completed.storeIdentifier == storeIdentifier,
        completed.offsetBytes == offsetBytes,
        completed.lengthBytes == lengthBytes
      else {
        throw ClosedEngineHelperError.installConfTargetMismatch
      }
      let conf = try InstallConf.parse(document)
      let disks = espDisks
      let workingDirectory = self.workingDirectory
      let store = completed.storeIdentifier
      let offset = completed.offsetBytes
      let length = completed.lengthBytes
      do {
        try await Task.detached {
          try InstallConfESPMountWriter(
            disks: disks,
            workingDirectory: workingDirectory
          ).write(
            conf,
            storeIdentifier: store,
            offsetBytes: offset,
            lengthBytes: length
          )
        }.value
        installConfConsumed = true
      } catch let error as InstallConfESPError where error.followedConfirmedWrite {
        installConfConsumed = true
        throw error
      }
    }
  }

  private struct CompletedEngineInstallPlan: Equatable, Sendable {
    let storeIdentifier: String
    let offsetBytes: UInt64
    let lengthBytes: UInt64
  }

  private struct RemovalJournal: Codable {
    let plan: OmarchyRemovalPlan
    let phase: String
    /// False until the install journals of the removed installation are set
    /// aside after "complete". Missing from records of earlier versions.
    let executionJournalsRetired: Bool?
  }

  public final class ClosedEngineXPCServiceEndpoint:
    NSObject, ClosedEngineXPCService
  {
    private let server: ClosedEngineHelperServer
    private let version: String
    private let retirement: PackageInstalledAppRetirement
    private let mayRetirePackageApps: Bool

    /// - Parameter version: the helper's build version, or empty when it
    ///   carries none.
    /// - Parameter mayRetirePackageApps: only a helper SMJobBless installed,
    ///   running from PrivilegedHelperTools, removes the package's app. An
    ///   ad hoc build's helper runs from inside that app and accepts any
    ///   client with the app's identifier, so it leaves it alone.
    public init(
      server: ClosedEngineHelperServer, version: String = "",
      retirement: PackageInstalledAppRetirement = PackageInstalledAppRetirement(),
      mayRetirePackageApps: Bool = ClosedEngineXPCServiceEndpoint.runsFromPrivilegedHelperTools()
    ) {
      self.server = server
      self.version = version
      self.retirement = retirement
      self.mayRetirePackageApps = mayRetirePackageApps
    }

    public static func runsFromPrivilegedHelperTools() -> Bool {
      let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
      return executable.path.hasPrefix("/Library/PrivilegedHelperTools/")
    }

    /// A retiring helper answers no, so the app treats it as gone and sets up
    /// a fresh one rather than sending it work.
    /// Answers at once, never waiting on the server's actor, so a helper
    /// busy with a long job still answers and is not mistaken for broken.
    public func ping(reply: @escaping @Sendable (Bool) -> Void) {
      reply(!server.isRetiring)
    }

    public func helperVersion(reply: @escaping @Sendable (String) -> Void) {
      reply(server.isRetiring ? "" : version)
    }

    public func recoveryAccount(
      action: String, ticket: String, username: String, password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
      let server = server
      Task {
        do {
          let result = try await server.recoveryAccount(
            action: action, ticket: ticket, username: username, password: password)
          reply(try JSONEncoder().encode(result), nil)
        } catch {
          let message =
            (error as? AccountSetupFailure)?.message
            ?? "The helper could not finish the recovery account setup. Your installation has been preserved."
          reply(try? JSONEncoder().encode(RecoveryAccountReply(message: message)), nil)
        }
      }
    }

    /// Answers at once: yes if no job runs and no other app holds the
    /// replacement; from then on no job starts, so the caller can replace
    /// this helper without cutting a job short.
    public func prepareForReplacement(
      token: String, reply: @escaping @Sendable (Bool) -> Void
    ) {
      reply(!token.isEmpty && server.work.beginReplacement(token: token))
    }

    public func cancelReplacement(token: String, reply: @escaping @Sendable () -> Void) {
      server.work.cancelReplacement(token: token)
      reply()
    }

    public func retirePackageInstalledApps(reply: @escaping @Sendable (String) -> Void) {
      let server = server
      let retirement = retirement
      guard mayRetirePackageApps else {
        return reply("not installed by SMJobBless; nothing changed")
      }
      Task.detached {
        guard !server.isRetiring else {
          return reply("helper is retiring; nothing changed")
        }
        reply(PackageInstalledAppRetirement.summary(retirement.run()))
      }
    }

    public func removal(
      ticket: String, confirmation: String, machineOwner: String, password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
      let server = server
      Task {
        do {
          guard ticket.isEmpty || UUID(uuidString: ticket) != nil,
            confirmation.utf8.count <= 256
          else { throw ClosedEngineHelperError.invalidOperation }
          let authorization =
            ticket.isEmpty
            ? nil : try MachineOwnerAuthorization(username: machineOwner, password: password)
          let result = try await server.removal(
            ticketID: UUID(uuidString: ticket), confirmation: confirmation,
            authorization: authorization)
          reply(try JSONEncoder().encode(result), nil)
        } catch {
          let message =
            (error as? RemovalFailure)?.message
            ?? "The helper could not prepare removal. Make sure this version of the app and its helper are installed and no installation is running."
          reply(try? JSONEncoder().encode(OmarchyRemovalReply(message: message)), nil)
        }
      }
    }

    public func removalFinalization(
      ticket: String, reply: @escaping @Sendable (String) -> Void
    ) {
      guard let id = UUID(uuidString: ticket) else {
        return reply(RemovalFinalization.unknown.rawValue)
      }
      let server = server
      Task { reply(await server.removalFinalization(ticketID: id).rawValue) }
    }

    public func submit(
      packageDirectory: FileHandle,
      operation: String,
      machineOwner: String,
      password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
      // NSXPCConnection.current() is only valid synchronously inside the
      // exported method, so the client proxy is captured before the Task.
      let client =
        NSXPCConnection.current()?
        .remoteObjectProxyWithErrorHandler { _ in
          // The peer exports no progress client: streaming stays off and the
          // authoritative reply path is untouched.
        } as? ClosedEngineProgressClient
      let sink = client.map(XPCJournalProgressSink.init(client:))
      let server = server
      Task {
        do {
          guard let operation = EngineHandoffOperation(rawValue: operation)
          else {
            throw ClosedEngineHelperError.invalidOperation
          }
          let authorization = try MachineOwnerAuthorization(
            username: machineOwner,
            password: password
          )
          let response = try await server.submit(
            packageDirectory: packageDirectory,
            authorization: authorization,
            operation: operation,
            progress: sink
          )
          reply(response, nil)
        } catch {
          reply(nil, EngineXPCErrorBridge.serviceError(for: error))
        }
      }
    }

    public func writeInstallConf(
      document: Data,
      storeIdentifier: String,
      offsetBytes: UInt64,
      lengthBytes: UInt64,
      machineOwner: String,
      password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
      let server = server
      Task {
        do {
          let authorization = try MachineOwnerAuthorization(
            username: machineOwner,
            password: password
          )
          try await server.writeInstallConf(
            document: document,
            storeIdentifier: storeIdentifier,
            offsetBytes: offsetBytes,
            lengthBytes: lengthBytes,
            authorization: authorization
          )
          let (data, error) = InstallConfXPCCodec.encodeReply(error: nil, encrypt: true)
          reply(data, error)
        } catch {
          let encrypt = (try? InstallConf.parse(document))?.encrypt ?? true
          let (data, nsError) = InstallConfXPCCodec.encodeReply(
            error: error,
            encrypt: encrypt
          )
          reply(data, nsError)
        }
      }
    }
  }

  enum EarlierRemovalProblem: Error, Equatable {
    /// A record that is not a plain file, can't be read, or stops before
    /// "complete".
    case unfinished
    /// A completed removal whose install journals couldn't be set aside.
    case installRecordUncleared
  }

  /// The gate before every new request: each earlier removal's record must
  /// show it completed, with the install journals of the installation it
  /// removed set aside. A completed removal whose journals are not set aside
  /// yet, because the helper stopped in between or moving them failed, gets
  /// them set aside now. No install can have run since that removal, as this
  /// gate refused it, so the journals found are that installation's.
  func settleEarlierRemovals(in workingDirectory: URL) throws {
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: workingDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    } catch {
      throw EarlierRemovalProblem.unfinished
    }
    for entry in entries
    where entry.lastPathComponent.hasPrefix("removal-") && entry.pathExtension == "json" {
      try settleCompletedRemoval(entry, in: workingDirectory)
    }
  }

  /// Sets aside the install journals once a removal's record says
  /// "complete", then records that durably. Does nothing for a record that
  /// already says so. `synchronize` is for tests.
  func settleCompletedRemoval(
    _ record: URL, in workingDirectory: URL,
    synchronize: (URL) throws -> Void = synchronizeDirectory
  ) throws {
    let properties = try? record.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard properties?.isRegularFile == true, properties?.isSymbolicLink != true,
      let data = try? Data(contentsOf: record),
      var journal = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      journal["phase"] as? String == "complete"
    else { throw EarlierRemovalProblem.unfinished }
    var only: [URL]?
    switch journal["executionJournalsRetired"] as? Bool {
    case .some(true):
      return
    case .some(false):
      break
    case .none:
      // Earlier versions set the journals aside in the same step and
      // recorded nothing, and an install may have run since. Journals created
      // before the record are the removed installation's and go, even if a
      // later install wrote to them; later ones stay. Dates that can't be
      // read decide nothing, so installing stays refused. With none left to
      // move, an earlier try may still have moved some, so the moves are
      // made durable and the record marked all the same.
      guard let legacy = legacyJournals(before: record, in: workingDirectory) else {
        throw EarlierRemovalProblem.installRecordUncleared
      }
      only = !legacy.old.isEmpty && legacy.old.count == legacy.total ? nil : legacy.old
    }
    do {
      let name = record.deletingPathExtension().lastPathComponent.dropFirst("removal-".count)
      try retireExecutionJournals(
        in: workingDirectory, removal: String(name), only: only, synchronize: synchronize)
      journal["executionJournalsRetired"] = true
      try writeRemovalRecord(
        JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]), to: record,
        in: workingDirectory)
    } catch {
      throw EarlierRemovalProblem.installRecordUncleared
    }
  }

  /// The install journals created no later than the record, and how many
  /// journals there are; nil when a date can't be read. The engine creates
  /// a journal once per plan and only appends to it, so its creation date
  /// tells which install it began with.
  private func legacyJournals(
    before record: URL, in workingDirectory: URL
  ) -> (old: [URL], total: Int)? {
    let journals = workingDirectory.appendingPathComponent(
      "execution-journals", isDirectory: true)
    guard FileManager.default.fileExists(atPath: journals.path) else { return ([], 0) }
    guard
      let recorded = try? record.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate,
      let entries = try? FileManager.default.contentsOfDirectory(
        at: journals, includingPropertiesForKeys: [.creationDateKey])
    else { return nil }
    var old: [URL] = []
    for entry in entries {
      guard let created = try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate
      else { return nil }
      if created <= recorded { old.append(entry) }
    }
    return (old, entries.count)
  }

  /// Writes a removal record and makes it, and its name, durable.
  func writeRemovalRecord(_ data: Data, to record: URL, in workingDirectory: URL) throws {
    try data.write(to: record, options: .atomic)
    let file = try FileHandle(forWritingTo: record)
    try file.synchronize()
    try file.close()
    try synchronizeDirectory(workingDirectory)
  }

  func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RemovalFailure(message: "The removal record couldn’t be saved.")
    }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw RemovalFailure(message: "The removal record couldn’t be saved.")
    }
  }

  /// Install journals are named by the plan's binding digest, and removal
  /// returns the disk to the layout that plan was made from. Left in place,
  /// a reinstall at the same size finds its earlier journal complete and
  /// reports success without writing anything. They are kept for diagnosis
  /// under `retired-execution-journals/<removal ticket>`: the whole
  /// directory, or with `only`, just those journals.
  ///
  /// Every call ends by making the moves durable, including moves an earlier
  /// call made before it failed, so a retry never skips that step.
  func retireExecutionJournals(
    in workingDirectory: URL, removal: String, only: [URL]? = nil,
    synchronize: (URL) throws -> Void = synchronizeDirectory
  ) throws {
    let fileManager = FileManager.default
    let journals = workingDirectory.appendingPathComponent(
      "execution-journals", isDirectory: true)
    let retired = workingDirectory.appendingPathComponent(
      "retired-execution-journals", isDirectory: true)
    func freshDestination() throws -> URL {
      if !fileManager.fileExists(atPath: retired.path) {
        try fileManager.createDirectory(
          at: retired, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      }
      var destination = retired.appendingPathComponent(removal, isDirectory: true)
      var attempt = 1
      while fileManager.fileExists(atPath: destination.path) {
        attempt += 1
        destination = retired.appendingPathComponent("\(removal)-\(attempt)", isDirectory: true)
      }
      return destination
    }
    if let only {
      if !only.isEmpty {
        let destination = try freshDestination()
        try fileManager.createDirectory(
          at: destination, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        for journal in only {
          try fileManager.moveItem(
            at: journal, to: destination.appendingPathComponent(journal.lastPathComponent))
        }
      }
    } else if fileManager.fileExists(atPath: journals.path) {
      try fileManager.moveItem(at: journals, to: freshDestination())
    }
    if fileManager.fileExists(atPath: journals.path) {
      try synchronize(journals)
    }
    if fileManager.fileExists(atPath: retired.path) {
      for entry in try fileManager.contentsOfDirectory(
        at: retired, includingPropertiesForKeys: nil)
      where entry.lastPathComponent.hasPrefix(removal) {
        try synchronize(entry)
      }
      try synchronize(retired)
    }
    try synchronize(workingDirectory)
  }

  public final class AuthenticatedEngineXPCListenerDelegate:
    NSObject, NSXPCListenerDelegate
  {
    private let clientCodeSigningRequirement: String
    private let endpoint: ClosedEngineXPCServiceEndpoint

    /// - Parameter helperVersion: the build version the helper reports; by
    ///   default the `CFBundleVersion` of its embedded Info.plist, or empty.
    public init(
      clientCodeSigningRequirement: String,
      server: ClosedEngineHelperServer,
      helperVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    ) throws {
      guard
        EngineCodeSigningRequirement.isValid(
          clientCodeSigningRequirement
        )
      else {
        throw ClosedEngineHelperError.invalidClientRequirement
      }
      self.clientCodeSigningRequirement = clientCodeSigningRequirement
      endpoint = ClosedEngineXPCServiceEndpoint(server: server, version: helperVersion)
    }

    public func listener(
      _ listener: NSXPCListener,
      shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
      connection.setCodeSigningRequirement(clientCodeSigningRequirement)
      connection.remoteObjectInterface = NSXPCInterface(
        with: ClosedEngineProgressClient.self
      )
      connection.exportedInterface = NSXPCInterface(
        with: ClosedEngineXPCService.self
      )
      connection.exportedObject = endpoint
      connection.activate()
      return true
    }
  }
#endif
