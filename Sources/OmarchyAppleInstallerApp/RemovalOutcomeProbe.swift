import Foundation
import OmarchyAppleInstallerTrustCore

/// Reads, without privileges, what a removal leaves behind, for when its
/// reply is lost.
enum RemovalOutcomeProbe {
  /// The helper's job file, binary and state directory are all gone, in two
  /// looks a second apart, so a helper another build is reinstalling at that
  /// moment is not mistaken for one that retired. A helper an installer
  /// package put in place never retires; see `helperStaysAfterRemoval`.
  static func helperRetired() async -> Bool {
    let paths = [
      InstallerProductIdentity.systemLaunchDaemonPath,
      "/Library/PrivilegedHelperTools/" + InstallerProductIdentity.helperIdentifier,
      InstallerProductIdentity.helperWorkingDirectory,
    ]
    func absent() -> Bool {
      paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
    }
    guard absent() else { return false }
    try? await Task.sleep(for: .seconds(1))
    return absent()
  }

  /// The registered helper is one an installer package put in place, which
  /// stays after a completed removal rather than retiring.
  static func helperStaysAfterRemoval(appCanInstallHelper: Bool) -> Bool {
    HelperRemovalFate.staysAfterRemoval(
      jobProgram: HelperRemovalFate.jobProgram(), appCanInstallHelper: appCanInstallHelper)
  }

  /// What the helper's records say about this removal, from `ask`. While
  /// it is busy, perhaps still finishing the removal, it is asked again, at
  /// most `attempts` times and no new question after `deadline` from the
  /// first; it then stays busy, which confirms nothing. With the client's
  /// 10-second answer timeout, the whole wait stays under about 40 seconds.
  /// Nil when it never answers, as older helpers don't.
  static func finalization(
    attempts: Int = 10, pause: Duration = .seconds(3), deadline: Duration = .seconds(30),
    ask: @Sendable () async -> RemovalFinalization?
  ) async -> RemovalFinalization? {
    let start = ContinuousClock.now
    var answer: RemovalFinalization?
    for attempt in 0..<attempts {
      if attempt > 0 {
        guard ContinuousClock.now - start + pause <= deadline else { break }
        try? await Task.sleep(for: pause)
        // A sleep can overrun, as while the Mac sleeps.
        guard ContinuousClock.now - start <= deadline else { break }
      }
      answer = await ask()
      if answer != .busy { break }
    }
    return answer
  }

  /// The size of the APFS container macOS runs from.
  static func macOSContainerBytes() -> UInt64? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["info", "-plist", "/"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return (info["APFSContainerSize"] as? NSNumber)?.uint64Value
  }
}
