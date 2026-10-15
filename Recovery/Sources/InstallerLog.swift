import Combine
import Foundation

// Only sanitized command output enters this log. The file keeps the current
// attempt in full; the UI receives a bounded tail, at most five times a second.
final class InstallerLog: ObservableObject {
  static let shared = InstallerLog()
  @Published private(set) var text = ""
  @Published private(set) var truncated = false
  let displayLimit: Int
  private let directory: URL
  private let lock = NSLock()
  private var tail = Data()
  private var tailTruncated = false
  private var updateScheduled = false
  private var file: URL?
  private var handle: FileHandle?
  private var temporary = true
  private var storageError: String?

  init(directory: URL = FileManager.default.temporaryDirectory, displayLimit: Int = 64 * 1024) {
    self.directory = directory
    self.displayLimit = max(1024, displayLimit)
    beginAttempt()
  }
  deinit { try? handle?.close() }

  func beginAttempt() {
    lock.lock()
    defer { lock.unlock() }
    try? handle?.close()
    handle = nil
    tail.removeAll(keepingCapacity: true)
    tailTruncated = false
    storageError = nil
    temporary = true
    let path = directory.appendingPathComponent("aurora-installer-" + UUID().uuidString + ".log")
    file = path
    if FileManager.default.createFile(
      atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
    {
      do { handle = try FileHandle(forWritingTo: path) } catch {
        storageError = error.localizedDescription
      }
    } else {
      storageError = "Could not create the attempt log."
    }
    scheduleUpdateLocked()
  }

  func append(_ message: String) { appendOutput("\n" + message + "\n") }

  func appendOutput(_ output: String) {
    guard !output.isEmpty else { return }
    let bytes = Data(output.utf8)
    lock.lock()
    defer { lock.unlock() }
    do { try handle?.write(contentsOf: bytes) } catch { storageError = error.localizedDescription }
    tail.append(bytes)
    if tail.count > displayLimit {
      tail.removeFirst(tail.count - displayLimit)
      // Do not start the display in the middle of a UTF-8 character.
      while let first = tail.first, first & 0xc0 == 0x80 { tail.removeFirst() }
      tailTruncated = true
    }
    scheduleUpdateLocked()
  }

  func persist(to url: URL) {
    lock.lock()
    defer { lock.unlock() }
    guard let source = file, source != url else { return }
    do {
      try handle?.synchronize()
      try FileManager.default.copyItem(at: source, to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      guard FileManager.default.contentsEqual(atPath: source.path, andPath: url.path) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let saved = try FileHandle(forWritingTo: url)
      try saved.seekToEnd()
      try handle?.close()
      handle = saved
      file = url
      // Only remove our temporary duplicate after a byte-identical copy.
      if temporary { try? FileManager.default.removeItem(at: source) }
      temporary = false
    } catch { storageError = "Could not save the full log: " + error.localizedDescription }
    scheduleUpdateLocked()
  }

  func fullText() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    if let storageError {
      throw NSError(
        domain: "AuroraInstallerLog", code: 1, userInfo: [NSLocalizedDescriptionKey: storageError])
    }
    guard let file else { return String(decoding: tail, as: UTF8.self) }
    return try String(contentsOf: file, encoding: .utf8)
  }

  private func scheduleUpdateLocked() {
    guard !updateScheduled else { return }
    updateScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      // Read the latest state here, so queued callbacks cannot restore a
      // previous attempt or enqueue a copy of the whole log per chunk.
      let snapshot = String(decoding: self.tail, as: UTF8.self)
      let clipped = self.tailTruncated
      let error = self.storageError
      self.updateScheduled = false
      self.lock.unlock()
      let display = error.map { "Log storage error: " + $0 + "\n" + snapshot } ?? snapshot
      if self.text != display { self.text = display }
      if self.truncated != clipped { self.truncated = clipped }
    }
  }
}

final class CommandLog {
  private let log: InstallerLog
  private var previous = ""
  init(_ heading: String, log: InstallerLog = .shared) {
    self.log = log
    log.append(heading)
  }
  func output(_ snapshot: String) {
    guard snapshot != previous else { return }
    if snapshot.hasPrefix(previous) {
      let delta = String(decoding: snapshot.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
      log.appendOutput(delta)
    } else {
      // Preserve diagnostics if a producer revises its output instead
      // of returning the cumulative snapshots used by our PTY helper.
      log.append("[Command output revised]")
      log.appendOutput(snapshot)
    }
    previous = snapshot
  }
}
