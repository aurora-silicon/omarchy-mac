import Foundation
import RecoveryAccountCore

// Opt-in native-account qualification on a disposable APFS image. This tool
// is not packaged in either installer. Refuse real/internal physical stores.
@main struct Qualification {
  static func main() throws {
    guard CommandLine.arguments.count == 5 else {
      fatalError("systemUUID dataUUID groupUUID prebootUUID")
    }
    let ids = Array(CommandLine.arguments.dropFirst())
    let target = RecoveryAccountTarget(
      volumeName: "Omarchy Account Fixture", systemUUID: ids[0], dataUUID: ids[1],
      groupUUID: ids[2], prebootUUID: ids[3])
    let info = try AccountNativeCommand.disk(target.dataUUID)
    guard info["Internal"] as? Bool == false,
      (info["VolumeName"] as? String) == "Omarchy Account Fixture - Data"
    else { throw AccountSetupFailure("Only a disposable external fixture is allowed.") }
    let password = Data("fixture-only".utf8)
    let created = try RecoveryAccountInstaller.prepare(
      target, username: "fixture_owner", password: password)
    guard ["prepared", "awaiting-ownership"].contains(created.phase) else {
      fatalError("wrong phase")
    }
    let repeated = try RecoveryAccountInstaller.prepare(
      target, username: "fixture_owner", password: password)
    guard created == repeated else { fatalError("not idempotent") }
    do {
      _ = try RecoveryAccountInstaller.prepare(
        target, username: "fixture_owner", password: Data("incorrect".utf8))
      fatalError("wrong password accepted")
    } catch is AccountSetupFailure {}
    let pending = try RecoveryAccountInstaller.finalize(target, password: password)
    guard ["prepared", "awaiting-ownership"].contains(pending.phase) else {
      fatalError("ownership invented")
    }
    do {
      try RecoveryAccountInstaller.requireOwnership(pending)
      fatalError("ungranted ownership accepted")
    } catch is AccountSetupFailure {}
    print("phase=\(pending.phase) conditionalCredentialRepair=\(pending.tokenReconciled)")
    print(
      "Native account create, persisted identity, repeat, wrong-password rejection and ungranted ownership checks passed."
    )
  }
}
