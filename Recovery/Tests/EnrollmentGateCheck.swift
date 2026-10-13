import Foundation

@main struct EnrollmentGateCheck {
  enum FixtureFailure: Error { case selectionFailed }
  static func main() throws {
    func check(
      _ policy: String?, _ expected: EnrollmentGateIssue?, recovery: Bool = true, root: Bool = true
    ) {
      precondition(
        EnrollmentGate.issue(isRecovery: recovery, isRoot: root, policy: policy) == expected)
    }
    check(nil, .notRecovery, recovery: false)
    check(nil, .rootRequired, root: false)
    check(nil, .cannotVerify)
    check("Current OS environment: macOS\nPairing: Paired", .notRecovery)
    check("Current OS environment: one true recoveryOS\nPairing: Paired", nil)
    check(" OS Type : one true recoveryOS\r\n Pairing : Paired\r\n", nil)
    check("Current OS environment: ordinary recoveryOS\nPairing: Paired", .powerButtonRequired)
    check("OS Type: recoveryOS\nPairing: Paired", .powerButtonRequired)
    check("OS Type: one true recoveryOS\nPairing: Unpaired", .wrongPair)
    check("OS Type: ordinary recoveryOS\nPairing: Not Paired", .wrongPair)
    check("Warning: use one true recoveryOS\nPairing: Paired", .cannotVerify)
    check("OS Type: not one true recoveryOS\nPairing: Paired", .cannotVerify)
    check("OS Type: one true recoveryOS\nPairing: Not Paired\nOther: Paired", .cannotVerify)
    check(
      "OS Type: one true recoveryOS\nCurrent OS environment: ordinary recoveryOS\nPairing: Paired",
      .powerButtonRequired)
    check("Current OS environment: one true recoveryOS\nOS Type: Paired", nil)
    check(
      "Current OS environment: one true recoveryOS\nCurrent OS environment: ordinary recoveryOS\nPairing: Paired",
      .cannotVerify)
    check("OS Type: one true recoveryOS\nPairing: Paired eventually", .cannotVerify)

    var selected = false
    var calls: [String] = []
    try RecoveryBootRepair.perform(
      isTargetDefault: {
        calls.append("read")
        return selected
      },
      selectTarget: {
        calls.append("select")
        selected = true
      }, shutDown: { calls.append("shutdown") })
    precondition(calls == ["read", "select", "read", "shutdown"])

    calls = []
    try RecoveryBootRepair.perform(
      isTargetDefault: {
        calls.append("read")
        return true
      }, selectTarget: { preconditionFailure("Already selected; no authorization needed") },
      shutDown: { calls.append("shutdown") })
    precondition(calls == ["read", "read", "shutdown"])

    var shutDown = false
    do {
      try RecoveryBootRepair.perform(
        isTargetDefault: { false },
        selectTarget: { throw FixtureFailure.selectionFailed },
        shutDown: { shutDown = true })
      preconditionFailure("Selection failure was accepted")
    } catch FixtureFailure.selectionFailed {}
    precondition(!shutDown)
    do {
      try RecoveryBootRepair.perform(
        isTargetDefault: { false }, selectTarget: {},
        shutDown: { shutDown = true })
      preconditionFailure("Failed readback was accepted")
    } catch RecoveryBootRepair.Failure.selectionNotVerified {}
    precondition(!shutDown)
    var reads = 0
    do {
      try RecoveryBootRepair.perform(
        isTargetDefault: {
          reads += 1
          return reads == 1
        },
        selectTarget: {}, shutDown: { shutDown = true })
      preconditionFailure("Changed startup selection was accepted")
    } catch RecoveryBootRepair.Failure.selectionNotVerified {}
    precondition(!shutDown)
    print(
      "PASS environment classifications; selection/readback/shutdown ordering; no shutdown on failed or changed selection"
    )
  }
}
