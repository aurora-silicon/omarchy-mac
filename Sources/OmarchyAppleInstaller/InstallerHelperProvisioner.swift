#if os(macOS)
  import Foundation
  import OSLog

  /// Where the privileged helper stands, as the app sees it.
  public enum InstallerHelperStatus: Equatable, Sendable {
    /// No helper is registered with launchd.
    case missing
    /// The helper answers and is the build this app carries.
    case current
    /// The helper answers but reports a different build, or none at all, as
    /// helpers installed by the installer package do; or it is loaded but
    /// refuses this app, as a helper from another build does.
    case outdated
    /// The helper is registered but launchd has not loaded it, because the
    /// person switched it off in Login Items.
    case disabled
    /// The helper is loaded but did not answer in time, as when it is busy
    /// verifying a large payload for another job. It is never replaced for
    /// that alone, which would end the job.
    case busy
  }

  /// What `InstallerHelperProvisioner.ensureCurrent` did.
  extension InstallerHelperProvisioningOutcome {
    var installed: Bool {
      self == .installedSilently || self == .installedWithDialog
    }
  }

  public enum InstallerHelperProvisioningOutcome: Equatable, Sendable {
    /// The helper was already current; nothing was installed.
    case alreadyCurrent
    /// Installed with the typed credentials and no system dialog.
    case installedSilently
    /// macOS refused the typed credentials, so its own administrator dialog
    /// was shown and the person approved it there.
    case installedWithDialog
    /// The typed name or password was not accepted locally. Nothing was
    /// attempted.
    case credentialsRejected
    /// The password is right but the account is not an administrator, and the
    /// helper needs installing, which only administrators may do.
    case notAdministrator
    /// The person cancelled macOS's administrator dialog, or macOS refused it.
    case cancelled
    /// The helper is switched off and was left that way.
    case disabled
    /// The helper is busy with another job; nothing was changed.
    case busy
    /// This build cannot install the helper itself.
    case unavailable
    /// Installation reported success but the helper does not answer, or the
    /// installation failed outright. The message is for diagnostics only.
    case failed(String)
  }

  /// Observes the installed helper. The shipping probe checks launchd's job
  /// file and asks the helper over XPC; tests supply a fake.
  public protocol InstallerHelperProbing: Sendable {
    /// Cheap and synchronous, safe on the main actor: whether launchd has the
    /// helper's job file.
    var isRegistered: Bool { get }
    /// How the helper answered a ping: yes, refused quickly, or not in time.
    func ping() async -> AuthenticatedEngineXPCSubmitter.PingResult
    /// True if the installed helper agrees to be replaced by this token (no
    /// job runs, no other app holds it, and it starts none meanwhile), false
    /// if it is working or held, nil if it can't be asked.
    func prepareForReplacement(token: String) async -> Bool?
    /// Lets a helper this token held take work again.
    func cancelReplacement(token: String) async
    /// For a helper that can't be asked: whether it is verifiably idle (no
    /// engine runs under it and no other copy of the installer, the only
    /// thing that sends it work, is open), at work, or unknown.
    func observeWork() async -> InstallerHelperWorkObservation
    /// Whether launchd has the helper's job loaded. Switching the helper off in
    /// Login Items unloads the job but leaves its file, while a helper from
    /// another build stays loaded and refuses this app.
    func isLoaded() async -> Bool
    /// The build the running helper reports, or nil when it reports none.
    func reportedVersion() async -> String?
  }

  public enum InstallerHelperWorkObservation: Equatable, Sendable {
    case idle
    case working
    /// The process list or the helper's job couldn't be read. Treated like
    /// working: a helper is never replaced on a guess.
    case unknown
  }

  public enum InstallerHelperBlessResult: Equatable, Sendable {
    case blessed
    /// macOS refused the authorization; nothing was installed.
    case refused
    /// The person cancelled macOS's administrator dialog.
    case cancelled
    /// This build cannot install the helper.
    case unavailable
    /// Authorized, but the last check before installing found the installed
    /// helper at work; nothing was installed.
    case declined
    case failed(String)
  }

  /// Installs the helper bundled in the app, replacing any installed copy.
  /// `confirm` runs after authorization succeeds and immediately before the
  /// installed copy is replaced, however long a dialog took; when it says no,
  /// nothing is installed and the result is `.declined`.
  public protocol InstallerHelperBlessing: Sendable {
    /// Uses the typed credentials and never shows a system dialog.
    func blessSilently(
      with authorization: MachineOwnerAuthorization,
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult
    /// Lets macOS show its own administrator dialog.
    func blessWithDialog(
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult
  }

  /// Follow-up work once the app has installed its own helper, such as
  /// removing the app the installer package left in /Applications. It runs
  /// in the background and can never hold up or fail the setup.
  public protocol InstallerHelperHousekeeping: Sendable {
    func afterInstall() async
  }

  public struct NoInstallerHelperHousekeeping: InstallerHelperHousekeeping {
    public init() {}
    public func afterInstall() async {}
  }

  /// The blesser for builds that still rely on the installer package to put
  /// the helper in place.
  public struct UnavailableInstallerHelperBlesser: InstallerHelperBlessing {
    public init() {}

    public func blessSilently(
      with authorization: MachineOwnerAuthorization,
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      .unavailable
    }

    public func blessWithDialog(
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      .unavailable
    }
  }

  /// Decides whether the privileged helper needs installing and installs it
  /// with the credentials the person typed for the action at hand. It keeps
  /// no credential: each call uses the one it is given and forgets it.
  public struct InstallerHelperProvisioner: Sendable {
    private let probe: any InstallerHelperProbing
    private let blesser: any InstallerHelperBlessing
    private let credentialValidator: any MachineOwnerCredentialValidating
    private let administrators: any HelperAdministratorChecking
    private let bundledHelperVersion: String?
    private let housekeeping: any InstallerHelperHousekeeping

    /// - Parameter bundledHelperVersion: the build of the helper this app
    ///   carries. When nil the app cannot tell builds apart, and any helper
    ///   that answers counts as current.
    /// - Parameter housekeeping: started, not awaited, after each install.
    public init(
      probe: any InstallerHelperProbing,
      blesser: any InstallerHelperBlessing,
      credentialValidator: any MachineOwnerCredentialValidating,
      administrators: any HelperAdministratorChecking,
      bundledHelperVersion: String?,
      housekeeping: any InstallerHelperHousekeeping = NoInstallerHelperHousekeeping()
    ) {
      self.probe = probe
      self.blesser = blesser
      self.credentialValidator = credentialValidator
      self.administrators = administrators
      self.bundledHelperVersion = bundledHelperVersion
      self.housekeeping = housekeeping
    }

    /// The build of the helper an app bundle carries: the `CFBundleVersion`
    /// of the Info.plist linked into the helper binary. Nil when the bundle
    /// has no helper there or the helper carries no version.
    public static func bundledHelperVersion(
      in bundle: Bundle = .main,
      label: String = InstallerProductIdentity.helperIdentifier
    ) -> String? {
      let helper = bundle.bundleURL
        .appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
        .appendingPathComponent(label, isDirectory: false)
      guard FileManager.default.isExecutableFile(atPath: helper.path),
        let info = CFBundleCopyInfoDictionaryForURL(helper as CFURL) as? [String: Any],
        let version = info["CFBundleVersion"] as? String, !version.isEmpty
      else {
        return nil
      }
      return version
    }

    /// The synchronous status the screens show: missing, or current as far as
    /// the job file tells. `probeStatus()` refines current into outdated or
    /// disabled.
    public var registrationStatus: InstallerHelperStatus {
      probe.isRegistered ? .current : .missing
    }

    /// Asks the helper, so it may take a few seconds when the helper is slow
    /// or switched off.
    public func probeStatus() async -> InstallerHelperStatus {
      guard probe.isRegistered else {
        return .missing
      }
      switch await probe.ping() {
      case .answered:
        break
      case .refused:
        // Loaded but refusing means another build that only accepts its own
        // app; it is replaced like any outdated helper, not reported as
        // switched off.
        return await probe.isLoaded() ? .outdated : .disabled
      case .noAnswer:
        // Slow is not broken: a loaded helper may be busy with another job.
        return await probe.isLoaded() ? .busy : .disabled
      }
      guard let bundledHelperVersion else {
        return .current
      }
      return await probe.reportedVersion() == bundledHelperVersion ? .current : .outdated
    }

    /// Makes the helper current for the action the person just authorized.
    /// The password is checked locally first, so a typo never leads to a
    /// system dialog; an administrator is required only if the helper has to
    /// be installed; macOS's dialog appears only when the credentials
    /// were right and macOS still refused to use them.
    ///
    /// - Parameter reenablingSwitchedOff: the person chose to turn a helper
    ///   they switched off in Login Items back on. Without it a switched-off
    ///   helper is left alone and reported as `.disabled`.
    public func ensureCurrent(
      _ authorization: MachineOwnerAuthorization,
      reenablingSwitchedOff: Bool = false
    ) async -> InstallerHelperProvisioningOutcome {
      do {
        try credentialValidator.validate(authorization)
      } catch {
        return .credentialsRejected
      }
      let status = await probeStatus()
      switch status {
      case .current:
        return .alreadyCurrent
      case .disabled where !reenablingSwitchedOff:
        return .disabled
      case .busy:
        return .busy
      case .missing, .outdated, .disabled:
        break
      }
      // Only installing needs an administrator; a standard account can use a
      // helper that is already current.
      guard administrators.isAdministrator(authorization.username) else {
        return .notAdministrator
      }
      // Replacing a helper ends its engine too, so it is replaced only with
      // proof that it is idle, and that proof is checked again immediately
      // before installing. A helper that answers is held for this app alone;
      // one that can't be asked (older, or refusing this app) counts as idle
      // only while no engine process runs under it.
      let token = UUID().uuidString
      let probe = probe
      let clearance: Clearance
      switch status {
      case .outdated:
        switch await probe.prepareForReplacement(token: token) {
        case true?:
          clearance = .held
        case false?:
          return .busy
        case nil:
          // The reply may have been lost after a hold was granted; release
          // it, which only the holder's token can, so the helper doesn't
          // refuse work until it lapses.
          await probe.cancelReplacement(token: token)
          guard await probe.observeWork() == .idle else { return .busy }
          clearance = .unaskable
        }
      default:
        clearance = .nothingInstalled
      }
      let confirm: @Sendable () async -> Bool = {
        await Self.stillClear(clearance, probe: probe, token: token)
      }
      let outcome = await bless(authorization, confirm: confirm)
      if !outcome.installed {
        await probe.cancelReplacement(token: token)
      }
      return outcome
    }

    private enum Clearance: Sendable, Equatable {
      case held
      case unaskable
      case nothingInstalled
    }

    /// The last check before installing, after any dialog: the hold is still
    /// this app's and the helper still idle, or, where nothing was installed,
    /// nothing another app has installed since is at work. A held helper can't
    /// start a job after this check. For one that can't be asked, a job could
    /// still start in the instant between this check and `SMJobBless`; an
    /// older helper has no way to refuse work, so that window is a documented
    /// migration limitation.
    private static func stillClear(
      _ clearance: Clearance, probe: any InstallerHelperProbing, token: String
    ) async -> Bool {
      switch clearance {
      case .held:
        return await probe.prepareForReplacement(token: token) == true
      case .unaskable, .nothingInstalled:
        if clearance == .nothingInstalled, !probe.isRegistered {
          return true
        }
        // Whatever is installed now is asked first: a newer helper another
        // app put in place meanwhile can be held, and must be.
        switch await probe.prepareForReplacement(token: token) {
        case true?: return true
        case false?: return false
        case nil: return await probe.observeWork() == .idle
        }
      }
    }

    private func bless(
      _ authorization: MachineOwnerAuthorization,
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperProvisioningOutcome {
      switch await blesser.blessSilently(with: authorization, confirm: confirm) {
      case .blessed:
        return await confirmCurrent(.installedSilently)
      case .refused:
        break
      case .cancelled:
        return .cancelled
      case .unavailable:
        return .unavailable
      case .declined:
        return .busy
      case .failed(let message):
        return .failed(message)
      }
      switch await blesser.blessWithDialog(confirm: confirm) {
      case .blessed:
        return await confirmCurrent(.installedWithDialog)
      case .refused, .cancelled:
        return .cancelled
      case .unavailable:
        return .unavailable
      case .declined:
        return .busy
      case .failed(let message):
        return .failed(message)
      }
    }

    /// After installing, the bundled build must be the one answering: a
    /// helper that is silent, or still reports another build, is a failure.
    private func confirmCurrent(
      _ outcome: InstallerHelperProvisioningOutcome
    ) async -> InstallerHelperProvisioningOutcome {
      switch await probeStatus() {
      case .current:
        let housekeeping = housekeeping
        Task.detached { await housekeeping.afterInstall() }
        return outcome
      case .outdated:
        return .failed("The helper was installed but an older build still answers.")
      case .missing, .disabled, .busy:
        return .failed("The helper was installed but does not answer.")
      }
    }
  }

  /// The shipping housekeeping: asks the freshly installed helper to remove
  /// the app the installer package left behind, and logs what it did.
  public struct SystemInstallerHelperHousekeeping: InstallerHelperHousekeeping {
    private static let logger = Logger(
      subsystem: InstallerProductIdentity.appIdentifier, category: "helper")
    private let submitter: @Sendable () throws -> AuthenticatedEngineXPCSubmitter

    public init(
      submitter: @escaping @Sendable () throws -> AuthenticatedEngineXPCSubmitter
    ) {
      self.submitter = submitter
    }

    public func afterInstall() async {
      guard let submitter = try? submitter() else {
        return
      }
      let summary = await submitter.retirePackageInstalledApps() ?? "no answer"
      Self.logger.info("package-installed app retirement: \(summary, privacy: .public)")
    }
  }

  /// The shipping probe: launchd's job file for the synchronous check, and
  /// the helper's own XPC service for the rest.
  public struct SystemInstallerHelperProbe: InstallerHelperProbing {
    private let submitter: @Sendable () throws -> AuthenticatedEngineXPCSubmitter

    /// - Parameter submitter: builds a connection to the helper from the
    ///   release configuration; a failure counts as a helper that does not
    ///   answer.
    public init(
      submitter: @escaping @Sendable () throws -> AuthenticatedEngineXPCSubmitter
    ) {
      self.submitter = submitter
    }

    public var isRegistered: Bool {
      FileManager.default.fileExists(
        atPath: InstallerProductIdentity.systemLaunchDaemonPath
      )
    }

    /// `launchctl print` needs no privileges for a system job and fails when
    /// launchd has no such job loaded.
    public func isLoaded() async -> Bool {
      let label = InstallerProductIdentity.helperIdentifier
      return await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
          try process.run()
        } catch {
          return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
      }.value
    }

    public func ping() async -> AuthenticatedEngineXPCSubmitter.PingResult {
      guard let submitter = try? submitter() else {
        return .refused
      }
      return await submitter.pingResult()
    }

    public func reportedVersion() async -> String? {
      guard let submitter = try? submitter() else {
        return nil
      }
      return await submitter.helperVersion()
    }

    public func prepareForReplacement(token: String) async -> Bool? {
      guard let submitter = try? submitter() else {
        return nil
      }
      return await submitter.prepareForReplacement(token: token)
    }

    public func cancelReplacement(token: String) async {
      await (try? submitter())?.cancelReplacement(token: token)
    }

    /// launchd reports the helper's pid without privileges, and `ps` lists
    /// every process's parent; an engine runs as the helper's child. Only a
    /// helper verifiably not running, or running with no child, while no other
    /// copy of the installer is open, counts as idle; a failed read is unknown.
    public func observeWork() async -> InstallerHelperWorkObservation {
      let label = InstallerProductIdentity.helperIdentifier
      return await Task.detached {
        switch Self.anotherInstallerIsOpen() {
        case true?: return .working
        case nil: return .unknown
        case false?: break
        }
        let launchd = Self.runWithStatus("/bin/launchctl", ["print", "system/\(label)"])
        switch launchd.status {
        case 0:
          break
        case 113:
          return .idle  // no such job: nothing runs
        default:
          return .unknown
        }
        let pidLines = launchd.output.split(separator: "\n").filter {
          $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ")
        }
        guard let line = pidLines.first else {
          // Loaded but not running: launchd prints a pid only for a live job.
          return launchd.output.contains("state = not running") ? .idle : .unknown
        }
        let pidText = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces)
        guard let pid = Int(pidText ?? ""), pid > 0 else {
          return .unknown
        }
        let table = Self.runWithStatus("/bin/ps", ["-axo", "ppid="])
        guard table.status == 0 else { return .unknown }
        let hasChild = table.output.split(separator: "\n").contains {
          Int($0.trimmingCharacters(in: .whitespaces)) == pid
        }
        return hasChild ? .working : .idle
      }.value
    }

    /// Another copy of the installer, of any build, name or user, is running:
    /// only an installer sends an older helper work. Only this process is
    /// excluded, by ID, so the same bundle open in another user's session, or
    /// an older process whose bundle was updated in place, still counts. Nil
    /// when the process list can't be verified.
    static func anotherInstallerIsOpen(
      processes: [PackageInstalledAppRetirement.RunningProcess]? =
        PackageInstalledAppRetirement.runningProcesses(),
      own: pid_t = getpid()
    ) -> Bool? {
      guard let processes else { return nil }
      return processes.contains { $0.pid != own && $0.mayBeInstaller }
    }

    private static func runWithStatus(
      _ path: String, _ arguments: [String]
    ) -> (status: Int32, output: String) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = arguments
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      do { try process.run() } catch { return (-1, "") }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

  }
#endif
