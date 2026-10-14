import CryptoKit
import Darwin
import Foundation

/// A durable snapshot of explicitly selected regular files. It never restores
/// boot policy or enclave state. Callers supply the same trusted paths on resume.
public final class RecoveryFileTransaction {
  private struct Entry: Codable {
    let path: String
    let present: Bool
    let mode: UInt16
    let uid: UInt32
    let gid: UInt32
    let flags: UInt32
    let backup: String
    let metadata: Bool
    let digest: String?
  }

  private let directory: URL
  private let entries: [Entry]

  public init(directory: URL, files: [URL], dataOnly: Set<URL> = []) throws {
    guard Set(files.map { $0.standardizedFileURL.path }).count == files.count else {
      throw AccountSetupFailure("Duplicate rollback file.")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var saved = [Entry]()
    for (index, file) in files.enumerated() {
      var info = stat()
      let present = lstat(file.path, &info) == 0
      guard present || errno == ENOENT else {
        throw AccountSetupFailure("Cannot inspect a rollback file.")
      }
      guard !present || (info.st_mode & S_IFMT) == S_IFREG else {
        throw AccountSetupFailure("Rollback requires a regular file.")
      }
      let backup = String(index) + ".before"
      var digest: String?
      if present {
        guard info.st_size >= 0, info.st_size <= 64 << 20 else {
          throw AccountSetupFailure("Rollback file is too large.")
        }
        let bytes = try Data(contentsOf: file)
        digest = Self.hash(bytes)
        try Self.write(bytes, to: directory.appendingPathComponent(backup))
      }
      saved.append(
        Entry(
          path: file.standardizedFileURL.path, present: present,
          mode: UInt16(info.st_mode & 0o7777), uid: info.st_uid, gid: info.st_gid,
          flags: info.st_flags, backup: backup, metadata: !dataOnly.contains(file), digest: digest))
    }
    self.directory = directory
    entries = saved
    try Self.write(
      try JSONEncoder().encode(saved), to: directory.appendingPathComponent("files.json"))
  }

  private init(directory: URL, entries: [Entry]) {
    self.directory = directory
    self.entries = entries
  }

  public static func resume(
    directory: URL, files: [URL],
    originalFiles: [URL]? = nil
  ) throws -> RecoveryFileTransaction {
    let manifest = directory.appendingPathComponent("files.json")
    var info = stat()
    guard lstat(manifest.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == geteuid(), (info.st_mode & 0o077) == 0, info.st_size <= 65536
    else { throw AccountSetupFailure("The rollback record is not trusted.") }
    let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: manifest))
    guard entries.map(\.path) == (originalFiles ?? files).map({ $0.standardizedFileURL.path }),
      entries.count == files.count,
      entries.enumerated().allSatisfy({ $0.element.backup == String($0.offset) + ".before" })
    else { throw AccountSetupFailure("The rollback target changed.") }
    let mapped = zip(entries, files).map { entry, file in
      Entry(
        path: file.standardizedFileURL.path, present: entry.present, mode: entry.mode,
        uid: entry.uid, gid: entry.gid, flags: entry.flags, backup: entry.backup,
        metadata: entry.metadata, digest: entry.digest)
    }
    let transaction = RecoveryFileTransaction(directory: directory, entries: mapped)
    try transaction.validateBackups()
    return transaction
  }

  private static func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private func validateBackups() throws {
    var info = stat()
    guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == geteuid(), (info.st_mode & 0o077) == 0
    else { throw AccountSetupFailure("The rollback directory is not trusted.") }
    for entry in entries where entry.present {
      let path = directory.appendingPathComponent(entry.backup)
      guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
        info.st_uid == geteuid(), (info.st_mode & 0o077) == 0,
        info.st_size >= 0, info.st_size <= 64 << 20,
        entry.digest == Self.hash(try Data(contentsOf: path))
      else { throw AccountSetupFailure("Saved rollback data did not verify.") }
    }
  }

  public func clearImmutableFlags() throws {
    for entry in entries where entry.present && entry.metadata {
      guard chflags(entry.path, 0) == 0 else {
        throw AccountSetupFailure("Cannot unlock the target metadata for its native update.")
      }
    }
  }

  public func commit(relocated: [String: URL] = [:]) throws {
    // A native update may replace a file and thereby drop its old schg flag.
    for entry in entries where entry.present && entry.metadata {
      let target = relocated[entry.path]?.path ?? entry.path
      guard chflags(target, entry.flags) == 0 else {
        throw AccountSetupFailure("Cannot restore the target metadata flags.")
      }
      try Self.flush(URL(fileURLWithPath: target))
    }
    try Self.write(Data("committed\n".utf8), to: directory.appendingPathComponent("status"))
  }

  public func restore() throws {
    // Validate all saved bytes before changing the first target.
    try validateBackups()
    var failures = [String]()
    for entry in entries {
      do {
        let target = URL(fileURLWithPath: entry.path)
        var info = stat()
        let present = lstat(entry.path, &info) == 0
        guard present || errno == ENOENT,
          !present || (info.st_mode & S_IFMT) == S_IFREG
        else { throw AccountSetupFailure("A rollback target is no longer a regular file.") }
        if present, entry.metadata, chflags(entry.path, 0) != 0 {
          throw AccountSetupFailure("Cannot unlock a rollback target.")
        }
        if entry.present {
          try Self.write(
            Data(contentsOf: directory.appendingPathComponent(entry.backup)), to: target,
            protect: entry.metadata)
          if entry.metadata {
            guard chown(entry.path, entry.uid, entry.gid) == 0,
              chmod(entry.path, mode_t(entry.mode)) == 0,
              chflags(entry.path, entry.flags) == 0
            else { throw AccountSetupFailure("Cannot restore rollback metadata.") }
            try Self.flush(target)
          }
        } else if present {
          try FileManager.default.removeItem(at: target)
          try Self.flushDirectory(target.deletingLastPathComponent())
        }
      } catch { failures.append(entry.path) }
    }
    guard failures.isEmpty else {
      throw AccountSetupFailure(
        "Could not restore \(failures.count) target metadata files; keep the saved rollback record."
      )
    }
    try Self.write(Data("restored\n".utf8), to: directory.appendingPathComponent("status"))
  }

  public static func write(_ bytes: Data, to path: URL, protect: Bool = true) throws {
    try bytes.write(to: path, options: .atomic)
    guard !protect || chmod(path.path, 0o600) == 0 else {
      throw AccountSetupFailure("Cannot protect rollback data.")
    }
    try flush(path)
    guard try Data(contentsOf: path) == bytes else {
      throw AccountSetupFailure("Saved rollback data did not verify.")
    }
    try flushDirectory(path.deletingLastPathComponent())
  }

  private static func flush(_ path: URL) throws {
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw AccountSetupFailure("Cannot open saved rollback data.") }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw AccountSetupFailure("Cannot flush saved rollback data.") }
  }

  public static func flushDirectory(_ path: URL) throws {
    let parent = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw AccountSetupFailure("Cannot open rollback directory.") }
    defer { close(parent) }
    guard fsync(parent) == 0 else { throw AccountSetupFailure("Cannot flush rollback directory.") }
  }
}
