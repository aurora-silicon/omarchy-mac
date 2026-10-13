import Foundation

// Interpret bputil's environment report separately from any command execution.
// Unknown output never authorizes enrollment.
enum EnrollmentGateIssue: String, Error, Identifiable, LocalizedError {
  case notRecovery, rootRequired, wrongPair, powerButtonRequired, cannotVerify
  var id: String { rawValue }

  var title: String {
    switch self {
    case .notRecovery: return "Open Aurora Installer in Recovery"
    case .rootRequired: return "Open the installer from Recovery"
    case .wrongPair: return "Open Omarchy’s paired Recovery"
    case .powerButtonRequired: return "Start Recovery with the power button"
    case .cannotVerify: return "Couldn’t verify the recovery environment"
    }
  }
  var message: String {
    switch self {
    case .notRecovery:
      return
        "Shut down, then hold the power button until Startup Options appears. Select Omarchy to finish setup."
    case .rootRequired:
      return
        "Launch Aurora Installer from Recovery’s Utilities menu or Terminal. No installation changes have been made."
    case .wrongPair:
      return
        "This Recovery belongs to a different installation. Aurora will select Omarchy as the startup disk and shut down. Once powered off, hold the power button continuously until Startup Options appears, then select Omarchy."
    case .powerButtonRequired:
      return
        "This is ordinary Recovery. Aurora will select Omarchy as the startup disk and shut down. Once powered off, hold the power button continuously until Startup Options appears, then select Omarchy. Do not press and release it first."
    case .cannotVerify:
      return
        "Aurora could not confirm that this is Omarchy’s paired power-button Recovery. No installation changes have been made. Restart into that Recovery and try again."
    }
  }
  var canRepairStartupSelection: Bool {
    self == .wrongPair || self == .powerButtonRequired
  }
  var errorDescription: String? { message }
}

enum EnrollmentGate {
  static func issue(isRecovery: Bool, isRoot: Bool, policy: String?) -> EnrollmentGateIssue? {
    guard isRecovery else { return .notRecovery }
    guard isRoot else { return .rootRequired }
    guard let policy else { return .cannotVerify }
    let fields = policy.split(whereSeparator: { $0.isNewline }).compactMap {
      line -> (String, String)? in
      guard let colon = line.firstIndex(of: ":") else { return nil }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      return (name, value)
    }
    // Match Asahi's precedence: the current environment is authoritative.
    // OS Type is an older fallback and can describe a different policy field.
    let current = fields.filter { $0.0 == "Current OS environment" }.map { $0.1.lowercased() }
    let environments =
      current.isEmpty ? fields.filter { $0.0 == "OS Type" }.map { $0.1.lowercased() } : current
    guard !environments.isEmpty, Set(environments).count == 1 else { return .cannotVerify }
    let environment = environments[0]
    if environment == "macos" { return .notRecovery }
    guard ["one true recoveryos", "ordinary recoveryos", "recoveryos"].contains(environment) else {
      return .cannotVerify
    }
    // bputil labels the target policy Paired/Unpaired. Match a complete
    // field value so warnings or "Not Paired" cannot count as approval.
    let paired = fields.contains { $0.1 == "Paired" }
    let unpaired = fields.contains { ["Unpaired", "Not Paired"].contains($0.1) }
    if unpaired && paired { return .cannotVerify }
    if unpaired { return .wrongPair }
    guard paired else { return .cannotVerify }
    return environment == "one true recoveryos" ? nil : .powerButtonRequired
  }
}

// Do not shut down after a failed selection or an unverified readback.
enum RecoveryBootRepair {
  enum Failure: Error { case selectionNotVerified }
  static func perform(
    isTargetDefault: () throws -> Bool,
    selectTarget: () throws -> Void,
    shutDown: () throws -> Void
  ) throws {
    if try !isTargetDefault() { try selectTarget() }
    guard try isTargetDefault() else { throw Failure.selectionNotVerified }
    try shutDown()
  }
}
