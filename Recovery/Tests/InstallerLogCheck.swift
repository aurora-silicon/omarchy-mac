import Combine
import Foundation

@main struct Check {
  static func spin(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.02))) }
  }
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aurora-log-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = InstallerLog(directory: root)
    var publications = 0
    let observer = log.$text.sink { _ in publications += 1 }
    defer { observer.cancel() }
    let saved = root.appendingPathComponent("saved-attempt.log")
    let command = CommandLog("$ fixture", log: log)
    command.output("first")
    command.output("first output\n")
    command.output("first output\n")  // A repeated PTY snapshot must not duplicate output.
    try require(
      log.fullText() == "\n$ fixture\nfirst output\n",
      "cumulative output must be appended exactly once")
    log.persist(to: saved)
    let inode =
      try FileManager.default.attributesOfItem(atPath: saved.path)[.systemFileNumber] as! NSNumber
    let started = Date()
    let chunk = String(repeating: "readable log output 0123456789\n", count: 32)
    let count = 20000
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      for _ in 0..<count { log.appendOutput(chunk) }
      log.appendOutput("END OF FIRST ATTEMPT\n")
      group.leave()
    }
    while group.wait(timeout: .now()) != .success { spin(0.02) }
    spin(0.3)
    let elapsed = Date().timeIntervalSince(started)
    let expected =
      "\n$ fixture\nfirst output\n" + String(repeating: chunk, count: count)
      + "END OF FIRST ATTEMPT\n"
    try require(log.fullText() == expected, "full file must retain every chunk")
    try require(
      log.text.utf8.count <= log.displayLimit && log.truncated, "live view must remain bounded")
    try require(log.text.hasSuffix("END OF FIRST ATTEMPT\n"), "live view must contain final output")
    try require(publications <= Int(ceil(elapsed / 0.2)) + 3, "updates must be coalesced")
    let afterInode =
      try FileManager.default.attributesOfItem(atPath: saved.path)[.systemFileNumber] as! NSNumber
    try require(inode == afterInode, "appending must not rewrite the log file")
    let permissions =
      try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as! NSNumber
    try require(permissions.intValue & 0o777 == 0o600, "saved log must stay private")
    log.appendOutput("QUEUED OLD OUTPUT\n")
    log.beginAttempt()
    log.appendOutput("SECOND ATTEMPT\n")
    spin(0.3)
    try require(
      log.text == "SECOND ATTEMPT\n" && !log.truncated,
      "queued updates must not restore an old attempt")
    try require(log.fullText() == "SECOND ATTEMPT\n", "new attempt must start a separate full log")
    let previous = try String(contentsOf: saved, encoding: .utf8)
    try require(
      previous == expected + "QUEUED OLD OUTPUT\n", "retry must leave the previous saved log intact"
    )
    log.appendOutput(String(repeating: "🦊éλ\n", count: 20000))
    spin(0.3)
    try require(
      log.text.utf8.count <= log.displayLimit && !log.text.contains("\u{FFFD}"),
      "tail clipping must preserve UTF-8")
    print(
      "PASS \(expected.utf8.count) bytes / \(count) chunks in \(String(format: "%.3f", elapsed))s; \(publications) UI publications; 64KiB display cap; complete append-only file; retry isolation; UTF-8; permissions"
    )
  }
  static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { fatalError(message) }
  }
}
