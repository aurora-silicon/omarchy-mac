import Foundation

/// Replace a whole metadata tree on its own filesystem. The original directory
/// remains a sibling until the caller's durable enrollment record commits.
enum RecoveryDirectorySwap {
  static func paths(target: URL, operation: String) -> (URL, URL) {
    let parent = target.deletingLastPathComponent()
    return (
      parent.appendingPathComponent(".aurora-var-before-" + operation),
      parent.appendingPathComponent(".aurora-var-next-" + operation)
    )
  }

  static func replace(
    source: URL, target: URL, operation: String, wasPresent: Bool,
    copy: (URL, URL) throws -> Void,
    checkpoint: (String) throws -> Void = { _ in }
  ) throws {
    let fm = FileManager.default
    let (backup, next) = paths(target: target, operation: operation)
    guard !fm.fileExists(atPath: backup.path), !fm.fileExists(atPath: next.path) else {
      throw AccountSetupFailure("An earlier iSC metadata copy needs recovery first.")
    }
    try copy(source, next)
    try checkpoint("copied")
    if wasPresent { try fm.moveItem(at: target, to: backup) }
    try RecoveryFileTransaction.flushDirectory(target.deletingLastPathComponent())
    try checkpoint("saved")
    try fm.moveItem(at: next, to: target)
    try RecoveryFileTransaction.flushDirectory(target.deletingLastPathComponent())
    try checkpoint("published")
  }

  static func restore(target: URL, operation: String, wasPresent: Bool) throws {
    let fm = FileManager.default
    let (backup, next) = paths(target: target, operation: operation)
    if fm.fileExists(atPath: backup.path) {
      if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
      try fm.moveItem(at: backup, to: target)
    } else if !wasPresent && fm.fileExists(atPath: target.path) {
      try fm.removeItem(at: target)
    }
    if fm.fileExists(atPath: next.path) { try fm.removeItem(at: next) }
    try RecoveryFileTransaction.flushDirectory(target.deletingLastPathComponent())
  }
}
