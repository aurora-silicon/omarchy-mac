import Foundation

/// The stub needs its version visible during native Startup Disk authorization,
/// then hidden again for the initial Finish Installation Recovery handoff.
public enum RecoveryVersionMetadata {
  public static func validate(_ data: Data) throws {
    guard
      let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      value["ProductName"] as? String == "macOS",
      let version = value["ProductVersion"] as? String, !version.isEmpty,
      let build = value["ProductBuildVersion"] as? String, !build.isEmpty
    else { throw AccountSetupFailure("The stub is missing valid macOS version metadata.") }
  }

  public static func showForStartupDisk(system: URL) throws {
    try setVisible(true, system: system)
  }

  public static func hideForInitialRecovery(system: URL) throws {
    guard
      FileManager.default.fileExists(atPath: system.appendingPathComponent(".IAPhysicalMedia").path)
    else { return }
    try setVisible(false, system: system)
  }

  private static func setVisible(_ visible: Bool, system: URL) throws {
    let core = system.appendingPathComponent("System/Library/CoreServices", isDirectory: true)
    let enabled = core.appendingPathComponent("SystemVersion.plist")
    let disabled = core.appendingPathComponent("SystemVersion-disabled.plist")
    let target = visible ? enabled : disabled
    let source = visible ? disabled : enabled
    let fm = FileManager.default
    if fm.fileExists(atPath: target.path) {
      try validate(RecoveryAccountInstaller.protectedRead(target, limit: 65536))
      guard !fm.fileExists(atPath: source.path) else {
        throw AccountSetupFailure(
          "The stub has conflicting macOS version metadata. Both files were preserved.")
      }
      return
    }
    let bytes = try RecoveryAccountInstaller.protectedRead(source, limit: 65536)
    try validate(bytes)
    try fm.moveItem(at: source, to: target)
    guard try RecoveryAccountInstaller.protectedRead(target, limit: 65536) == bytes else {
      throw AccountSetupFailure("The stub version metadata did not verify.")
    }
  }
}
