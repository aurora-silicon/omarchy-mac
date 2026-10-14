import Darwin
import Foundation

struct AccountSetupFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

@main struct RecoveryFileTransactionCheck {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let existing = root.appendingPathComponent("metadata.plist")
    let missing = root.appendingPathComponent("new-token.plist")
    let before = Data("original metadata".utf8)
    try before.write(to: existing)
    precondition(chmod(existing.path, 0o640) == 0)
    let backup = root.appendingPathComponent("snapshot")
    let transaction = try RecoveryFileTransaction(directory: backup, files: [existing, missing])
    try Data("partial native update".utf8).write(to: existing, options: .atomic)
    try Data("partial token".utf8).write(to: missing)
    let resumed = try RecoveryFileTransaction.resume(directory: backup, files: [existing, missing])
    try resumed.restore()
    let restored = try Data(contentsOf: existing)
    precondition(restored == before)
    precondition(!fm.fileExists(atPath: missing.path))
    var info = stat()
    precondition(lstat(existing.path, &info) == 0 && (info.st_mode & 0o7777) == 0o640)
    do {
      _ = try RecoveryFileTransaction.resume(directory: backup, files: [missing, existing])
      preconditionFailure("Changed rollback target accepted")
    } catch {}
    // Repeating an interrupted restoration is safe and keeps original bytes.
    try transaction.restore()
    let restoredAgain = try Data(contentsOf: existing)
    precondition(restoredAgain == before)
    // A damaged backup must be rejected before any target is restored.
    try Data("tampered".utf8).write(to: backup.appendingPathComponent("0.before"))
    try Data("keep until valid rollback".utf8).write(to: existing)
    do {
      try transaction.restore()
      preconditionFailure("Damaged backup accepted")
    } catch {}
    let notRestored = try Data(contentsOf: existing)
    precondition(notRestored == Data("keep until valid rollback".utf8))
    try before.write(to: backup.appendingPathComponent("0.before"))
    try transaction.restore()
    // UUID-validated callers can remap the same relative files after a mount rename.
    let newMount = root.appendingPathComponent("renamed-mount")
    try fm.createDirectory(at: newMount, withIntermediateDirectories: false)
    let relocated = newMount.appendingPathComponent("metadata.plist")
    let relocatedMissing = newMount.appendingPathComponent("new-token.plist")
    let remapped = try RecoveryFileTransaction.resume(
      directory: backup, files: [relocated, relocatedMissing], originalFiles: [existing, missing])
    try remapped.restore()
    let remappedBytes = try Data(contentsOf: relocated)
    precondition(remappedBytes == before)
    let moved = root.appendingPathComponent("metadata-disabled.plist")
    precondition(chflags(existing.path, UInt32(UF_NODUMP)) == 0)
    let commitBackup = root.appendingPathComponent("commit-snapshot")
    let committing = try RecoveryFileTransaction(directory: commitBackup, files: [existing])
    try committing.clearImmutableFlags()
    try fm.moveItem(at: existing, to: moved)
    try committing.commit(relocated: [existing.standardizedFileURL.path: moved])
    precondition(lstat(moved.path, &info) == 0 && info.st_flags & UInt32(UF_NODUMP) != 0)
    let status = try Data(contentsOf: commitBackup.appendingPathComponent("status"))
    precondition(status == Data("committed\n".utf8))
    precondition(chflags(moved.path, 0) == 0)
    print(
      "PASS file rollback bytes, original absence, mode, interruption resume and target binding")
  }
}
