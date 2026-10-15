import Foundation

/// File recovery is allowed before enrollment starts. A lost kmutil response
/// is ambiguous, so retries retain the matching bundle and enroll it again.
enum RecoveryInstallationPhase: String, Codable, CaseIterable {
  case prepared, policyRequested, policyAuthorized, bundleInstalled
  case enrollmentRequested, enrolled, finalizing, committed

  var mayRestoreFiles: Bool {
    [.prepared, .policyRequested, .policyAuthorized, .bundleInstalled].contains(self)
  }
  var needsEnrollment: Bool {
    self != .enrolled && self != .finalizing && self != .committed
  }
}

struct RecoveryInstallationJournal: Codable {
  let operation: String
  let systemUUID: String
  let groupUUID: String
  let espUUID: String
  let stage1SHA256: String
  let stage2SHA256: String
  let originalFiles: [String]
  let replacedISC: Bool
  let iscVarWasPresent: Bool
  var phase: RecoveryInstallationPhase

  func validate(system: String, group: String, esp: String, stage1: String, stage2: String) throws {
    guard operation.hasPrefix("operation-"),
      UUID(uuidString: String(operation.dropFirst("operation-".count))) != nil,
      systemUUID == system, groupUUID == group, espUUID == esp,
      stage1SHA256 == stage1, stage2SHA256 == stage2
    else {
      throw RecoveryFailure(
        message:
          "The interrupted setup belongs to another installation or build. Its rollback files were preserved."
      )
    }
  }
}

/// Commands and file operations are injected so the same phase runner can be
/// fault-tested without calling bputil, kmutil or a live disk.
enum RecoveryInstallationCoordinator {
  static func run(
    phase: RecoveryInstallationPhase,
    persist: (RecoveryInstallationPhase) throws -> Void,
    authorizePolicy: () throws -> Void, installBundle: () throws -> Void,
    verifyBundle: () throws -> Void, enroll: () throws -> Void,
    finalize: () throws -> Void, commit: () throws -> Void
  ) throws {
    if phase.mayRestoreFiles {
      try persist(.policyRequested)
      try authorizePolicy()
      try persist(.policyAuthorized)
      try installBundle()
      try persist(.bundleInstalled)
    }
    try verifyBundle()
    if phase.needsEnrollment {
      try persist(.enrollmentRequested)
      try enroll()
      try persist(.enrolled)
    }
    if phase != .committed {
      try persist(.finalizing)
      try finalize()
      try commit()
      try persist(.committed)
    }
  }
}
