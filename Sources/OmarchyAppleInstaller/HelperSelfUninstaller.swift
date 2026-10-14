#if os(macOS)
  import Foundation
  import OSLog

  /// Removes the helper from the Mac once a removal has completed, so no
  /// Omarchy trace is left: its launchd job file, its binary in
  /// PrivilegedHelperTools and its whole state directory, including retired
  /// install journals. Only a helper the app installed itself with
  /// `SMJobBless` goes, because only that app can set it up again at the next
  /// install. A helper an installer package put in place stays: nothing but
  /// the package can register it again, so removing it would leave the app
  /// unable to install until the package is run again.
  public protocol HelperSelfUninstalling: Sendable {
    /// Whether a completed removal uninstalls this helper. When false the
    /// helper stays and keeps taking work.
    var uninstallsAfterRemoval: Bool { get }
    /// Called after the removal reply is built, only when
    /// `uninstallsAfterRemoval`; it must let that reply reach the app before
    /// the helper goes away.
    func uninstallAfterRemoval()
  }

  /// For tests and any caller that is not the running helper.
  public struct NoHelperSelfUninstall: HelperSelfUninstalling {
    public init() {}
    public var uninstallsAfterRemoval: Bool { false }
    public func uninstallAfterRemoval() {}
  }

  /// The one form in which the helper and the app compare helper binary
  /// paths: symlinks resolved, then `.` and `..` removed. Both sides of the
  /// keep-or-uninstall rule use it, so they never disagree about a path.
  public enum HelperBinaryPath {
    public static func normalized(_ path: String) -> String {
      URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
  }

  /// The app's unprivileged view of the same rule: whether the registered
  /// helper is one that stays after a completed removal.
  public enum HelperRemovalFate {
    /// - Parameters:
    ///   - jobProgram: the `Program` of the helper's job file, nil when there
    ///     is no job file or it can't be read.
    ///   - appCanInstallHelper: whether this app declares its helper for
    ///     `SMJobBless`; the helper of the same build then declares
    ///     `SMAuthorizedClients`.
    public static func staysAfterRemoval(
      jobProgram: String?, appCanInstallHelper: Bool,
      blessedBinary: String = "/Library/PrivilegedHelperTools/"
        + InstallerProductIdentity.helperIdentifier
    ) -> Bool {
      guard let jobProgram else { return false }
      return !appCanInstallHelper
        || HelperBinaryPath.normalized(jobProgram) != HelperBinaryPath.normalized(blessedBinary)
    }

    /// The `Program` of a launchd job file, read without privileges; nil when
    /// the file is missing, unreadable or names no program.
    public static func jobProgram(
      atPath path: String = InstallerProductIdentity.systemLaunchDaemonPath
    ) -> String? {
      (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
      }?["Program"] as? String
    }
  }

  public struct LaunchdHelperSelfUninstaller: HelperSelfUninstalling {
    private static let logger = Logger(
      subsystem: InstallerProductIdentity.appIdentifier, category: "helper")

    private let label: String
    private let jobFile: URL
    private let binary: URL
    private let workingDirectory: URL
    private let delay: Duration
    private let unload: @Sendable (String) -> Void
    private let exitProcess: @Sendable () -> Void
    public let uninstallsAfterRemoval: Bool

    /// The defaults are the fixed, identity-derived paths and this process;
    /// tests pass a temporary root and record `unload` and `exitProcess`
    /// instead of running them.
    ///
    /// - Parameters:
    ///   - executable: the running helper's binary.
    ///   - declaresAuthorizedClients: whether the helper's embedded Info.plist
    ///     names the app allowed to install it (`SMAuthorizedClients`). Only
    ///     builds that can install their helper themselves carry it; ad hoc
    ///     builds leave it out and rely on the installer package.
    public init(
      label: String = InstallerProductIdentity.helperIdentifier,
      jobFile: URL = URL(fileURLWithPath: InstallerProductIdentity.systemLaunchDaemonPath),
      binary: URL = URL(
        fileURLWithPath: "/Library/PrivilegedHelperTools/"
          + InstallerProductIdentity.helperIdentifier),
      workingDirectory: URL = URL(
        fileURLWithPath: InstallerProductIdentity.helperWorkingDirectory, isDirectory: true),
      delay: Duration = .seconds(2),
      unload: @escaping @Sendable (String) -> Void = LaunchdHelperSelfUninstaller.bootout,
      exitProcess: @escaping @Sendable () -> Void = { exit(0) },
      executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
      declaresAuthorizedClients: Bool = LaunchdHelperSelfUninstaller.declaresAuthorizedClients(
        Bundle.main.infoDictionary)
    ) {
      self.label = label
      self.jobFile = jobFile
      self.binary = binary
      self.workingDirectory = workingDirectory
      self.delay = delay
      self.unload = unload
      self.exitProcess = exitProcess
      uninstallsAfterRemoval = Self.installedBySMJobBless(
        executable: executable, binary: binary,
        declaresAuthorizedClients: declaresAuthorizedClients)
    }

    /// `SMJobBless` copies the helper of a build that declares its authorized
    /// clients to the fixed binary path in PrivilegedHelperTools, and that
    /// build's app can bless it again. Both are needed: the installer package
    /// runs the helper from inside the app in /Applications, and the private
    /// ad hoc package copies a helper without `SMAuthorizedClients` to
    /// PrivilegedHelperTools; neither app can set its helper up again.
    static func installedBySMJobBless(
      executable: URL, binary: URL, declaresAuthorizedClients: Bool
    ) -> Bool {
      guard declaresAuthorizedClients else { return false }
      return HelperBinaryPath.normalized(executable.path)
        == HelperBinaryPath.normalized(binary.path)
    }

    /// Whether a helper's embedded Info.plist names the app allowed to
    /// install it. `Packaging/helper-plists` writes the key only for builds
    /// with a client requirement, the ones that can bless their helper.
    public static func declaresAuthorizedClients(_ info: [String: Any]?) -> Bool {
      guard let clients = info?["SMAuthorizedClients"] as? [Any] else { return false }
      return !clients.isEmpty
    }

    /// Deletes the files at once, so the app sees no helper from this moment
    /// and a later install blesses a fresh one (which replaces this job and
    /// ends this process), then unloads and exits after the delay that lets
    /// the removal reply reach the app. Does nothing for a helper the app did
    /// not install.
    public func uninstallAfterRemoval() {
      guard uninstallsAfterRemoval else { return }
      removeFiles()
      let uninstaller = self
      Task.detached {
        // The suspending clock stops while the Mac sleeps, so the delay still
        // gives the reply time to reach the app after it wakes.
        try? await Task.sleep(for: uninstaller.delay, clock: .suspending)
        uninstaller.unloadAndExit()
      }
    }

    func uninstallNow() {
      guard uninstallsAfterRemoval else { return }
      removeFiles()
      unloadAndExit()
    }

    private func unloadAndExit() {
      unload(label)
      exitProcess()
    }

    private func removeFiles() {
      for item in [jobFile, binary, workingDirectory] {
        do {
          if FileManager.default.fileExists(atPath: item.path) {
            try FileManager.default.removeItem(at: item)
          }
        } catch {
          Self.logger.error(
            "could not remove \(item.path, privacy: .public): \(String(describing: error), privacy: .public)"
          )
        }
      }
    }

    /// Asks launchd to unload the helper's own job. launchd then stops this
    /// process, so the request is started, not waited on.
    public static func bootout(_ label: String) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = ["bootout", "system/\(label)"]
      try? process.run()
      Thread.sleep(forTimeInterval: 1)
    }
  }
#endif
