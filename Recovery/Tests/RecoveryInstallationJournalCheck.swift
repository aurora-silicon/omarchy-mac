import Foundation

struct RecoveryFailure: Error { let message: String }

@main struct RecoveryInstallationJournalCheck {
  enum Injected: Error { case stop }
  static func main() throws {
    for phase in RecoveryInstallationPhase.allCases {
      let record = RecoveryInstallationJournal(
        operation: "operation-" + UUID().uuidString, systemUUID: "system", groupUUID: "group",
        espUUID: "esp", stage1SHA256: "first", stage2SHA256: "second", originalFiles: [],
        replacedISC: false, iscVarWasPresent: false, phase: phase)
      let resumed = try JSONDecoder().decode(
        RecoveryInstallationJournal.self, from: JSONEncoder().encode(record))
      try resumed.validate(
        system: "system", group: "group", esp: "esp", stage1: "first", stage2: "second")
      precondition(resumed.phase == phase)
      do {
        try resumed.validate(
          system: "other", group: "group", esp: "esp", stage1: "first", stage2: "second")
        preconditionFailure("Changed target accepted")
      } catch {}
      do {
        try resumed.validate(
          system: "system", group: "group", esp: "esp", stage1: "first", stage2: "new")
        preconditionFailure("Changed bundle accepted")
      } catch {}
    }
    precondition(RecoveryInstallationPhase.bundleInstalled.mayRestoreFiles)
    precondition(!RecoveryInstallationPhase.enrollmentRequested.mayRestoreFiles)
    precondition(RecoveryInstallationPhase.enrollmentRequested.needsEnrollment)
    precondition(!RecoveryInstallationPhase.enrolled.needsEnrollment)
    precondition(!RecoveryInstallationPhase.finalizing.mayRestoreFiles)
    let steps = [
      "policyRequested", "authorize", "policyAuthorized", "bundle", "bundleInstalled",
      "verify", "enrollmentRequested", "enroll", "enrolled", "finalizing",
      "finalize", "commit", "committed",
    ]
    for stop in steps {
      var observed = [String]()
      var durable = RecoveryInstallationPhase.prepared
      func step(_ name: String) throws {
        observed.append(name)
        if name == stop { throw Injected.stop }
      }
      do {
        try RecoveryInstallationCoordinator.run(
          phase: .prepared,
          persist: { phase in
            try step(phase.rawValue)
            durable = phase
          },
          authorizePolicy: { try step("authorize") }, installBundle: { try step("bundle") },
          verifyBundle: { try step("verify") }, enroll: { try step("enroll") },
          finalize: { try step("finalize") }, commit: { try step("commit") })
        preconditionFailure("Fault was not injected")
      } catch Injected.stop {}
      precondition(observed == Array(steps.prefix(through: steps.firstIndex(of: stop)!)))
      if observed.contains("enroll") { precondition(!durable.mayRestoreFiles) }
      if observed.contains("finalize") { precondition(durable == .finalizing) }
    }
    for phase in [
      RecoveryInstallationPhase.enrollmentRequested, .enrolled, .finalizing, .committed,
    ] {
      var invoked = [String]()
      try RecoveryInstallationCoordinator.run(
        phase: phase, persist: { _ in },
        authorizePolicy: { preconditionFailure("Repeated policy mutation") },
        installBundle: { preconditionFailure("Overwrote retained bundle") },
        verifyBundle: { invoked.append("verify") }, enroll: { invoked.append("enroll") },
        finalize: { invoked.append("finalize") }, commit: { invoked.append("commit") })
      precondition(invoked.first == "verify")
      precondition(invoked.contains("enroll") == (phase == .enrollmentRequested))
      precondition(invoked.contains("finalize") == (phase != .committed))
    }
    print("PASS installation interruption phases, target/build binding and ambiguous enrollment")
  }
}
